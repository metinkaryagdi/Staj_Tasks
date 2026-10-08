# Kontrol listesi 1: simülatöre saniyede 50 istek gönderildiğinde saniyede 20'si kabul ediliyor, kalanı 429 ve
# Retry-After alıyor.
#
# Simülatör yalnızca bu test için her isteği kabul edecek şekilde (Success=100) ve haber göndermeden yeniden başlatılır:
# böylece kabul edilen her istek veritabanında bir kayıt olur, her 429 hız sınırındandır. Fatura Servisi test boyunca
# durdurulur ki simülatöre yalnızca k6 istek göndersin. Sonda ikisi de ayar dosyasındaki değerlerle geri gelir.
param([int]$Rate = 50, [int]$Seconds = 10)

. "$PSScriptRoot\_common.ps1"

Write-Title "Hız sınırı: saniyede $Rate istek, $Seconds saniye"

Invoke-Compose @('--profile', 'iki-kopya', 'stop', 'invoice-service', 'invoice-service-2')
Write-Host '  Fatura Servisi durduruldu (simülatöre yalnızca k6 istek gönderecek).' -ForegroundColor DarkGray
Restart-Simulator @{
    Simulator__Rates__Success = 100; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0
    Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0; Webhooks__Enabled = 'false'
}
$limitLine = Get-SimulatorLog | Where-Object { $_ -match 'Rate limit:' } | Select-Object -Last 1
Write-Host ('  ' + ($limitLine -replace '^.*Rate limit:', 'Hız sınırı ayarı:')) -ForegroundColor DarkGray
$limit = if ($limitLine -match 'Rate limit: (\d+)') { [int]$Matches[1] } else { throw 'Hız sınırı log satırı bulunamadı.' }

$prefix = New-Prefix 'RL'
Write-Step "k6: saniyede $Rate istek, $Seconds sn, fatura öneki $prefix"
$from = (Get-Date).ToUniversalTime().AddSeconds(-1).ToString('yyyy-MM-dd HH:mm:ss')
Invoke-K6 'hiz-siniri.js' @{ RATE = $Rate; DURATION = "${Seconds}s"; PREFIX = $prefix; SUMMARY_FILE = 'hiz-siniri-k6.json' } |
    ForEach-Object { Write-Host "  $_" }
Start-Sleep -Seconds 1
$k6 = Get-Content (Join-Path $OutputDir 'hiz-siniri-k6.json') -Raw | ConvertFrom-Json

# Simülatör logu: kabul edilen her istek "ERP request #... invoice=<önek>", reddedilen her istek "reason=rateLimited".
$lines = Get-SimulatorLogSince $from
$accepted = @($lines | Where-Object { $_ -match 'ERP request #' -and $_.Contains("invoice=$prefix") })
$rejected = @($lines | Where-Object { $_ -match 'reason=rateLimited' })

Write-Step 'Simülatör logundan saniye saniye (UTC)'
$secondList = @(($accepted + $rejected) | ForEach-Object { $_.Substring(0, 19) } | Sort-Object -Unique)
$table = foreach ($s in $secondList) {
    $a = @($accepted | Where-Object { $_.StartsWith($s) }).Count
    $r = @($rejected | Where-Object { $_.StartsWith($s) }).Count
    [pscustomobject]@{ Saniye = $s; Gelen = $a + $r; Kabul = $a; 'Reddedilen (429)' = $r }
}
$table | Format-Table -AutoSize | Out-String | Write-Host

Write-DbHeader 'Kabul edilenler kaydedildi, reddedilenler kaydedilmedi' "Fatura öneki: $prefix"
Show-ErpQuery ("SELECT to_char(date_trunc('second', received_at), 'YYYY-MM-DD HH24:MI:SS') AS saniye, count(*) AS kayit " +
    "FROM invoices WHERE invoice_number LIKE '$prefix%' GROUP BY 1 ORDER BY 1;")
$saved = [int]@(Get-ErpRows "SELECT count(*) FROM invoices WHERE invoice_number LIKE '$prefix%';")[0]

# İlk ve son saniye k6'nın başladığı / bittiği yarım saniyelerdir; tam saniyeler aradakiler.
$full = @($table | Select-Object -Skip 1 | Select-Object -SkipLast 1)
$retryCheck = $k6.checks | Where-Object { $_.name -like '429*' }

$checks = @(
    # constant-arrival-rate süre sonunda bir istek fazla başlatabilir (500 yerine 501).
    (Write-DbVerdict "k6'nın gönderdiği ($($Rate * $Seconds) civarı) her istek simülatör logunda" `
        "k6 $($k6.requests), log $($accepted.Count + $rejected.Count) (kabul $($accepted.Count) + 429 $($rejected.Count))" `
        ($k6.requests -ge $Rate * $Seconds -and $accepted.Count + $rejected.Count -eq $k6.requests)),
    (Write-DbVerdict "tam saniyelerin ($($full.Count)) her birinde $limit kabul" `
        (($full | ForEach-Object { $_.Kabul }) -join ', ') `
        ($full.Count -gt 0 -and @($full | Where-Object { $_.Kabul -ne $limit }).Count -eq 0)),
    (Write-DbVerdict "hiçbir saniyede $limit'den fazla kabul yok" `
        "en çok $(($table | Measure-Object Kabul -Maximum).Maximum)" `
        (@($table | Where-Object { $_.Kabul -gt $limit }).Count -eq 0)),
    (Write-DbVerdict 'her 429 cevabında Retry-After: 1 ve "Rate limit exceeded"' `
        "$($retryCheck.passes) geçti, $($retryCheck.fails) kaldı" ($retryCheck.fails -eq 0)),
    (Write-DbVerdict "veritabanında kabul edilen kadar kayıt ($($accepted.Count))" "$saved" ($saved -eq $accepted.Count))
)

Write-Step 'Simülatör ve Fatura Servisi ayar dosyasındaki değerlerle geri getiriliyor'
Restart-Simulator
Invoke-Compose @('start', 'invoice-service')

Write-Result (@($checks | Where-Object { -not $_ }).Count -eq 0) "Saniyede $Rate istekte saniyede $limit kabul, kalanı 429 + Retry-After"
