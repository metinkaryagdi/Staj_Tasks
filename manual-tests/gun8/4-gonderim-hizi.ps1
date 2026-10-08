# Fatura Servisi simülatörün hız sınırını bilerek gönderiyor; iki kopya birlikte de sınırı aşmıyor.
#
# Servisin iki kopyası (5090, 5091) aynı veritabanıyla çalışır. k6 $Count faturayı iki kopyaya dağıtarak hızla gönderir;
# kuyruk boşalana kadar beklenir. Simülatör ayar dosyasındaki değerlerle çalışır (hata oranları, haberler açık).
# Simülatör logundan saniye saniye gelen POST sayısı çıkarılır (hız sınırından geçen + hız sınırı 429'u); hiçbir saniyede
# sınırı geçmemeli, hız sınırı 429'u toplam POST'un %5'ini geçmemeli. Saniye saniye tablonun tamamı manual-tests\output'a
# yazılır. Sonda ikinci kopya durdurulur.
param([int]$Count = 1200, [int]$Rate = 100, [int]$TimeoutMinutes = 15)

. "$PSScriptRoot\_common.ps1"

Write-Title "Gönderim hızı: iki kopya, $Count fatura"

try {
    Restart-Simulator
    $limitLine = Get-SimulatorLog | Where-Object { $_ -match 'Rate limit: \d+' } | Select-Object -Last 1
    $limit = if ($limitLine -match 'Rate limit: (\d+)') { [int]$Matches[1] } else { throw 'Hız sınırı log satırı bulunamadı.' }
    Restart-InvoiceService -WithSecondCopy
    foreach ($c in 'staj-tasks-invoice-service-1', 'staj-tasks-invoice-service-2-1') {
        $line = docker logs $c 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'ERP settings:' } | Select-Object -Last 1
        if ($line -match '(maxConcurrentSends=\S+ sendsPerSecond=\S+)') { Write-Host "  $c $($Matches[1])" -ForegroundColor DarkGray }
    }

    $customer = 'HIZ-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $seconds = [math]::Ceiling($Count / $Rate)
    Write-Step "k6: saniyede $Rate fatura, $seconds sn, iki kopyaya dağıtılarak (müşteri kodu $customer)"
    $from = (Get-Date).ToUniversalTime().AddSeconds(-1).ToString('yyyy-MM-dd HH:mm:ss')
    Invoke-K6 'fatura-gonder.js' @{
        BASE_URLS = 'http://invoice-service:8080,http://invoice-service-2:8080'; RATE = $Rate; DURATION = "${seconds}s"
        CUSTOMER = $customer; SUMMARY_FILE = 'gonderim-hizi-k6.json'
    } | ForEach-Object { Write-Host "  $_" }
    $k6 = Read-K6Summary 'gonderim-hizi-k6.json'

    Write-Step 'Kuyruğun boşalması bekleniyor'
    $pendingSql = "SELECT count(*) FROM erp_outbox o JOIN invoices i ON i.invoice_number = o.invoice_number " +
        "WHERE i.customer_code = '$customer' AND o.status = 'Bekliyor';"
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        $pending = [int]@(Get-ServiceRows $pendingSql)[0]
        Write-Host "  $(Get-Date -Format 'HH:mm:ss') kuyrukta $pending" -ForegroundColor DarkGray
        if ($pending -gt 0) { Start-Sleep -Seconds 15 }
    } while ($pending -gt 0 -and (Get-Date) -lt $deadline)

    # Simülatöre gelen her POST: hız sınırından geçen ("ERP request #N invoice=... behavior=") ya da reddedilen
    # ("reason=rateLimited"). Geç cevapta istemci bırakınca yazılan ikinci "ERP request #N ... client disconnected"
    # satırı POST değildir, sayılmaz.
    $lines = Get-SimulatorLogSince $from
    $posts = @($lines | Where-Object { $_ -match 'ERP request #\d+ invoice=\S+ behavior=' -or $_ -match 'reason=rateLimited' })
    $rateLimited = @($posts | Where-Object { $_ -match 'reason=rateLimited' })
    $busy = @($posts | Where-Object { $_ -match 'reason=busy' })

    $perSecond = @($posts | Group-Object { $_.Substring(0, 19) } | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{
            Saniye           = $_.Name
            POST             = $_.Count
            'Hiz siniri 429' = @($_.Group | Where-Object { $_ -match 'reason=rateLimited' }).Count
        }
    })
    $csv = Join-Path $OutputDir "gonderim-hizi-saniye-$customer.csv"
    $perSecond | Export-Csv $csv -NoTypeInformation -Encoding UTF8
    $max = ($perSecond | Measure-Object POST -Maximum).Maximum
    $busiest = @($perSecond | Where-Object { $_.POST -eq $max } | Select-Object -First 3)

    Write-Step "Simülatör logundan saniye saniye POST (tamamı: $csv)"
    Write-Host "  $($perSecond.Count) saniye, $($posts.Count) POST; saniye başına POST dağılımı:"
    $perSecond | Group-Object POST | Sort-Object { [int]$_.Name } | ForEach-Object {
        Write-Host ("    {0,2} POST: {1,4} saniye" -f $_.Name, $_.Count)
    }
    Write-Host "  En yoğun saniyeler: $(($busiest | ForEach-Object { "$($_.Saniye) ($($_.POST))" }) -join ', ')"
    $span = ([datetime]$perSecond[-1].Saniye - [datetime]$perSecond[0].Saniye).TotalSeconds + 1
    Write-Host ("  Ortalama: {0:N1} POST/sn ({1} - {2}, {3} sn)" -f ($posts.Count / $span), $perSecond[0].Saniye, $perSecond[-1].Saniye, $span)

    Write-Step 'Kopyalara göre POST yapılan deneme (servis logları, check=first ya da notFound)'
    $byCopy = foreach ($c in 'staj-tasks-invoice-service-1', 'staj-tasks-invoice-service-2-1') {
        $sent = @(docker logs --since 30m $c 2>&1 | ForEach-Object { "$_" } |
            Where-Object { $_ -match 'ERP send invoice=\S+ attempt=' -and $_ -match 'check=(first|notFound)' })
        [pscustomobject]@{ Kopya = $c; POST = $sent.Count }
    }
    $byCopy | Format-Table -AutoSize | Out-String | Write-Host

    Write-DbHeader 'Faturaların son durumu ve kuyruk' "Müşteri kodu: $customer"
    Show-ServiceQuery ("SELECT i.status AS fatura, o.status AS kuyruk, count(*) FROM invoices i JOIN erp_outbox o " +
        "ON o.invoice_number = i.invoice_number WHERE i.customer_code = '$customer' GROUP BY 1, 2 ORDER BY 1, 2;")
    $created = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE customer_code = '$customer';")[0]
    $range = @(Get-ServiceRows "SELECT min(invoice_number) || ' ' || max(invoice_number) FROM invoices WHERE customer_code = '$customer';")[0] -split ' '
    $erpWhere = "invoice_number BETWEEN '$($range[0])' AND '$($range[1])'"
    Show-ErpQuery "SELECT count(DISTINCT invoice_number) AS fatura, count(*) AS kayit FROM invoices WHERE $erpWhere;"
    $dupes = [int]@(Get-ErpRows "SELECT count(*) FROM (SELECT invoice_number FROM invoices WHERE $erpWhere GROUP BY 1 HAVING count(*) > 1) d;")[0]

    $ratio = if ($posts.Count) { 100.0 * $rateLimited.Count / $posts.Count } else { 0 }
    $copies = @($byCopy | Where-Object { $_.POST -gt 0 }).Count
    $checks = @(
        (Write-DbVerdict "k6'nın gönderdiği her fatura alındı ($($k6.requests))" "$created" ($created -eq $k6.requests)),
        (Write-DbVerdict 'kuyruk boşaldı (Bekliyor kalmadı)' "$pending" ($pending -eq 0)),
        (Write-DbVerdict 'iki kopya da POST yaptı' "$copies kopya" ($copies -eq 2)),
        (Write-DbVerdict "hiçbir saniyede $limit'den fazla POST yok" "en çok $max" ($max -le $limit)),
        (Write-DbVerdict "hız sınırı 429'u toplam POST'un %5'ini geçmiyor" `
            ("{0} / {1} = %{2:N2} (Meşgul 429 ayrıca: {3})" -f $rateLimited.Count, $posts.Count, $ratio, $busy.Count) ($ratio -le 5)),
        (Write-DbVerdict 'simülatörde birden fazla kaydı olan fatura yok' "$dupes" ($dupes -eq 0))
    )
}
finally {
    Write-Step 'İkinci kopya durduruluyor'
    Invoke-Compose @('--profile', 'iki-kopya', 'stop', 'invoice-service-2')
}

Write-Result (@($checks | Where-Object { -not $_ }).Count -eq 0) "İki kopya birlikte saniyede en çok $limit POST, hız sınırı 429'u %5'in altında"
