# Hız sınırından kaynaklanan 429 ile Meşgul davranışından kaynaklanan 429 loglarda ayrı görünüyor ve ayrı sayılıyor.
#
# Simülatör Success=50, Busy=50 ile ve haber göndermeden yeniden başlatılır; k6 saniyede 50 istek gönderir. Her saniye 20
# istek sınırdan geçer (bunların yaklaşık yarısı Meşgul 429 alır), kalan 30 hız sınırı 429'u alır. Loglardaki sayılar,
# k6'nın cevap başlığından ayırdığı sayılarla karşılaştırılır. Fatura Servisi test boyunca durdurulur; sonda ikisi de
# ayar dosyasındaki değerlerle geri gelir.
param([int]$Rate = 50, [int]$Seconds = 5)

. "$PSScriptRoot\_common.ps1"

Write-Title "İki tür 429: hız sınırı ve Meşgul (saniyede $Rate istek, $Seconds saniye)"

# Hata olsa da simülatör ve servis ayar dosyasındaki değerlerle geri gelir.
try {
    Invoke-Compose @('--profile', 'iki-kopya', 'stop', 'invoice-service', 'invoice-service-2')
    Write-Host '  Fatura Servisi durduruldu (simülatöre yalnızca k6 istek gönderecek).' -ForegroundColor DarkGray
    Restart-Simulator @{
        Simulator__Rates__Success = 50; Simulator__Rates__Busy = 50; Simulator__Rates__ServerError = 0
        Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0; Webhooks__Enabled = 'false'
    }

    $prefix = New-Prefix 'T429'
    Write-Step "k6: saniyede $Rate istek, $Seconds sn, fatura öneki $prefix"
    $from = (Get-Date).ToUniversalTime().AddSeconds(-1).ToString('yyyy-MM-dd HH:mm:ss')
    Invoke-K6 'hiz-siniri.js' @{ RATE = $Rate; DURATION = "${Seconds}s"; PREFIX = $prefix; SUMMARY_FILE = 'iki-429-k6.json' } |
        ForEach-Object { Write-Host "  $_" }
    Start-Sleep -Seconds 1
    $k6 = Read-K6Summary 'iki-429-k6.json'
    $k6RateLimited = [int](Get-K6Check $k6 'hız sınırı 429 (*').passes
    $k6Busy = [int](Get-K6Check $k6 'meşgul*').passes

    $lines = Get-SimulatorLogSince $from
    $rateLimited = @($lines | Where-Object { $_ -match 'status=429 reason=rateLimited' })
    $busy = @($lines | Where-Object { $_ -match 'status=429 reason=busy' -and $_.Contains("invoice=$prefix") })
    $success = @($lines | Where-Object { $_ -match 'behavior=Success status=202' -and $_.Contains("invoice=$prefix") })

    Write-Step 'Simülatör logundan birer örnek satır'
    foreach ($sample in @($rateLimited | Select-Object -First 1) + @($busy | Select-Object -First 1)) { Write-Host "  $sample" }

    Write-Step 'Simülatör logundan saniye saniye (UTC)'
    $secondList = @(($rateLimited + $busy + $success) | ForEach-Object { $_.Substring(0, 19) } | Sort-Object -Unique)
    $table = foreach ($s in $secondList) {
        [pscustomobject]@{
            Saniye                  = $s
            'Kabul (202)'           = @($success | Where-Object { $_.StartsWith($s) }).Count
            'Meşgul 429'            = @($busy | Where-Object { $_.StartsWith($s) }).Count
            'Hız sınırı 429'        = @($rateLimited | Where-Object { $_.StartsWith($s) }).Count
        }
    }
    $table | Format-Table -AutoSize | Out-String | Write-Host

    Write-Step 'Toplam (log)'
    [pscustomobject]@{
        'Kabul (202)' = $success.Count; 'Meşgul 429 (reason=busy)' = $busy.Count; 'Hız sınırı 429 (reason=rateLimited)' = $rateLimited.Count
    } | Format-Table -AutoSize | Out-String | Write-Host

    Write-DbHeader 'Meşgul ve hız sınırı 429 alanlar kaydedilmedi' "Fatura öneki: $prefix"
    Show-ErpQuery "SELECT count(*) AS kayit FROM invoices WHERE invoice_number LIKE '$prefix%';"
    $saved = [int]@(Get-ErpRows "SELECT count(*) FROM invoices WHERE invoice_number LIKE '$prefix%';")[0]

    # Meşgul satırlarındaki Retry-After (5-30 sn) hız sınırınınkinden (1 sn) ayrı.
    $busyRetry = @($busy | ForEach-Object { if ($_ -match 'retryAfter=(\d+)s') { [int]$Matches[1] } })
    $busyRetryRange = if ($busyRetry.Count) { "$(($busyRetry | Measure-Object -Minimum).Minimum)-$(($busyRetry | Measure-Object -Maximum).Maximum) sn" } else { '-' }

    $checks = @(
        (Write-DbVerdict 'her iki türden de 429 oluştu' "hız sınırı $($rateLimited.Count), Meşgul $($busy.Count)" `
            ($rateLimited.Count -gt 0 -and $busy.Count -gt 0)),
        (Write-DbVerdict "log reason=rateLimited sayısı = k6'nın 'Rate limit exceeded' sayısı" `
            "log $($rateLimited.Count), k6 $k6RateLimited" ($rateLimited.Count -eq $k6RateLimited)),
        (Write-DbVerdict "log reason=busy sayısı = k6'nın 'ERP is busy' sayısı" `
            "log $($busy.Count), k6 $k6Busy" ($busy.Count -eq $k6Busy)),
        (Write-DbVerdict 'her 429 iki türden biri, hız sınırı 429 cevaplarında Retry-After: 1' `
            "türsüz 429: $((Get-K6Check $k6 'her 429*').fails), Retry-After kalan: $((Get-K6Check $k6 '*Retry-After*').fails); Meşgul Retry-After $busyRetryRange" `
            ((Get-K6Check $k6 'her 429*').fails -eq 0 -and (Get-K6Check $k6 '*Retry-After*').fails -eq 0)),
        (Write-DbVerdict "logdaki toplam = k6'nın gönderdiği ($($k6.requests))" "$($success.Count + $busy.Count + $rateLimited.Count)" `
            ($success.Count + $busy.Count + $rateLimited.Count -eq $k6.requests)),
        (Write-DbVerdict "veritabanında yalnızca kabul edilenler ($($success.Count))" "$saved" ($saved -eq $success.Count))
    )
}
finally {
    Write-Step 'Simülatör ve Fatura Servisi ayar dosyasındaki değerlerle geri getiriliyor'
    Restart-Simulator
    Invoke-Compose @('start', 'invoice-service')
}

Write-Result (@($checks | Where-Object { -not $_ }).Count -eq 0) 'İki tür 429 loglarda ayrı görünüyor ve ayrı sayılıyor'
