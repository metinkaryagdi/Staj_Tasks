# Her fatura isteğinin işlenmesi 50 ile 200 ms arasında rastgele sürüyor; süreler ayar dosyasından okunuyor.
#
# A: ayar dosyasındaki değerlerle (50-200 ms) saniyede 10 istek, 20 sn (hız sınırının altında, hepsi kabul edilir).
#    Simülatör logundaki processing= değerleri ve k6'nın ölçtüğü cevap süreleri gösterilir.
# B: simülatör ortam değişkeniyle 300-300 ms'ye çekilip 20 istek daha gönderilir: sürenin ayardan okunduğu görülür.
# Her ikisinde Success=100 ve haber kapalı; Fatura Servisi test boyunca durdurulur. Sonda ikisi de ayar dosyasındaki
# değerlerle geri gelir.
. "$PSScriptRoot\_common.ps1"

Write-Title 'İşlem süresi: 50-200 ms, ayar dosyasından'

$quiet = @{
    Simulator__Rates__Success = 100; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0
    Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0; Webhooks__Enabled = 'false'
}

# Saniyede $Rate istek, $Seconds sn; logdaki processing= değerleri ve k6 özeti.
function Measure-Processing([string]$Name, [int]$Rate, [int]$Seconds) {
    $prefix = New-Prefix $Name
    Write-Step "k6: saniyede $Rate istek, $Seconds sn, fatura öneki $prefix"
    $from = (Get-Date).ToUniversalTime().AddSeconds(-1).ToString('yyyy-MM-dd HH:mm:ss')
    $file = "islem-suresi-$Name-k6.json"
    Invoke-K6 'hiz-siniri.js' @{ RATE = $Rate; DURATION = "${Seconds}s"; PREFIX = $prefix; SUMMARY_FILE = $file } |
        ForEach-Object { Write-Host "  $_" }
    Start-Sleep -Seconds 1
    $k6 = Read-K6Summary $file
    $values = @(Get-SimulatorLogSince $from | Where-Object { $_.Contains("invoice=$prefix") } |
        ForEach-Object { if ($_ -match 'processing=(\d+)ms') { [int]$Matches[1] } })
    $stats = $values | Measure-Object -Minimum -Maximum -Average
    [pscustomobject]@{ Prefix = $prefix; K6 = $k6; Values = $values; Stats = $stats }
}

function Show-Processing($m) {
    Write-Host ("  Simülatör logu: {0} istek, processing en az {1} ms, en çok {2} ms, ortalama {3:N0} ms" -f `
        $m.Values.Count, $m.Stats.Minimum, $m.Stats.Maximum, $m.Stats.Average)
    $d = $m.K6.duration
    Write-Host ("  k6 cevap süresi: en az {0:N1} ms, medyan {1:N1} ms, p95 {2:N1} ms, en çok {3:N1} ms" -f `
        $d.min, $d.med, $d.'p(95)', $d.max)
}

try {
    Invoke-Compose @('--profile', 'iki-kopya', 'stop', 'invoice-service', 'invoice-service-2')
    Write-Host '  Fatura Servisi durduruldu (simülatöre yalnızca k6 istek gönderecek).' -ForegroundColor DarkGray

    Write-Step 'A) Ayar dosyasındaki değerler'
    Restart-Simulator $quiet
    $a = Measure-Processing 'PA' 10 20
    Show-Processing $a
    Write-Host '  Dağılım (logdaki processing=, 50 ms aralıklarla):'
    foreach ($low in 50, 100, 150) {
        $high = if ($low -eq 150) { 200 } else { $low + 49 }
        $n = @($a.Values | Where-Object { $_ -ge $low -and $_ -le $high }).Count
        Write-Host ("    {0,3}-{1,3} ms: {2,3}  {3}" -f $low, $high, $n, ('#' * [math]::Ceiling($n / 2)))
    }

    Write-Step 'B) Ortam değişkeniyle 300-300 ms'
    $fixed = $quiet.Clone()
    $fixed['Simulator__ProcessingMinMilliseconds'] = 300
    $fixed['Simulator__ProcessingMaxMilliseconds'] = 300
    Restart-Simulator $fixed
    $b = Measure-Processing 'PB' 10 2
    Show-Processing $b

    Write-DbHeader 'Kabul edilen her istek kaydedildi' "Fatura önekleri: $($a.Prefix), $($b.Prefix)"
    Show-ErpQuery ("SELECT left(invoice_number, 2) AS test, count(*) AS kayit FROM invoices " +
        "WHERE invoice_number LIKE '$($a.Prefix)%' OR invoice_number LIKE '$($b.Prefix)%' GROUP BY 1 ORDER BY 1;")
    $savedA = [int]@(Get-ErpRows "SELECT count(*) FROM invoices WHERE invoice_number LIKE '$($a.Prefix)%';")[0]
    $savedB = [int]@(Get-ErpRows "SELECT count(*) FROM invoices WHERE invoice_number LIKE '$($b.Prefix)%';")[0]

    $checks = @(
        (Write-DbVerdict "A: k6'nın her isteği logda processing= ile ($($a.K6.requests))" "$($a.Values.Count)" `
            ($a.Values.Count -eq $a.K6.requests -and $a.Values.Count -gt 0)),
        (Write-DbVerdict 'A: her processing 50-200 ms arasında' "$($a.Stats.Minimum)-$($a.Stats.Maximum) ms" `
            ($a.Stats.Minimum -ge 50 -and $a.Stats.Maximum -le 200)),
        (Write-DbVerdict 'A: süreler aralığa yayılmış (en az < 70 ms, en çok > 180 ms)' "$($a.Stats.Minimum) / $($a.Stats.Maximum) ms" `
            ($a.Stats.Minimum -lt 70 -and $a.Stats.Maximum -gt 180)),
        (Write-DbVerdict "A: k6'nın en kısa cevabı 50 ms'den uzun" ("{0:N1} ms" -f $a.K6.duration.min) ($a.K6.duration.min -ge 50)),
        (Write-DbVerdict 'B: her processing 300 ms' "$($b.Stats.Minimum)-$($b.Stats.Maximum) ms ($($b.Values.Count) istek)" `
            ($b.Values.Count -gt 0 -and $b.Stats.Minimum -eq 300 -and $b.Stats.Maximum -eq 300)),
        (Write-DbVerdict "B: k6'nın en kısa cevabı 300 ms'den uzun" ("{0:N1} ms" -f $b.K6.duration.min) ($b.K6.duration.min -ge 300)),
        (Write-DbVerdict 'veritabanında kabul edilen her istek' "A $savedA / $($a.Values.Count), B $savedB / $($b.Values.Count)" `
            ($savedA -eq $a.Values.Count -and $savedB -eq $b.Values.Count))
    )
}
finally {
    Write-Step 'Simülatör ve Fatura Servisi ayar dosyasındaki değerlerle geri getiriliyor'
    Restart-Simulator
    Invoke-Compose @('start', 'invoice-service')
}

Write-Result (@($checks | Where-Object { -not $_ }).Count -eq 0) 'İşlem süresi 50-200 ms arasında ve ayar dosyasından okunuyor'
