# Kontrol listesi 4: en az üç kez denenen bir faturanın izinde her deneme, bekleme süresi ve sonuç ayrı ayrı görünüyor.
#   .\manual-tests\gun12\5-iz-uc-deneme.ps1
# Simülatör önce her isteğe 500 verir (ServerError %100); fatura üç kez denendikten sonra simülatör her isteği kabul
# edecek şekilde (Success %100) yeniden başlatılır. Yeniden başlarken yapılan deneme "ulaşılamadı" ile bitebilir.
. "$PSScriptRoot\_common.ps1"

Write-Title 'Kontrol listesi 4: en az üç kez denenen faturanın izi'
Restart-Simulator (Get-SimSettings 'ServerError')
# Script hata verse de simülatör varsayılan ayarlarına döner.
try {
    Write-Step 'Fatura oluşturuluyor'
    $since = [DateTimeOffset]::UtcNow.AddSeconds(-5)
    $number = (New-ServiceInvoice).InvoiceNumber
    Write-Host "  $number"

    Write-Step 'Üç deneme bekleniyor'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ([int]@(Get-ServiceRows "SELECT send_attempt_count FROM invoices WHERE invoice_number = '$number';")[0] -lt 3) {
        if ($watch.Elapsed.TotalSeconds -gt 120) { throw '120 sn içinde üç deneme olmadı.' }
        Start-Sleep -Seconds 1
    }
    Write-Host ("  {0:N0} sn: üç deneme yapıldı" -f $watch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
    Restart-Simulator (Get-SimSettings 'Success')
    Wait-InvoicesIn @($number) @('Onaylandı', 'Reddedildi') 180 'karar aldı' | Out-Null
    Wait-EventsDone @($number) 60 | Out-Null

    Write-Step "Jaeger'daki iz"
    $trace = Get-InvoiceTrace $number $since
    Show-Trace $trace 'gun12-5-iz-uc-deneme.txt'

    Write-Step 'Denemeler (outbox.attempt span''leri)'
    $attempts = @($trace.Spans | Where-Object { $_.Name -eq 'outbox.attempt' } | Sort-Object Start)
    $table = $attempts | ForEach-Object {
        [pscustomobject]@{
            Deneme = $_.Tags['outbox.attempt']; 'Başlangıç ms' = $_.Start; Sonuç = $_.Tags['outbox.outcome']; Yol = $_.Tags['outbox.check']
            HTTP = $_.Tags['erp.http_status']; 'Bekleme sn' = [math]::Round([double]$_.Tags['outbox.wait_seconds'], 3); Hata = $_.Tags['otel.status_description']
        }
    }
    $table | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    Show-ServiceQuery "SELECT attempt_count, status, last_error FROM erp_outbox WHERE invoice_number = '$number';"

    $numbered = @($attempts | ForEach-Object { $_.Tags['outbox.attempt'] }) -join ','
    $expectedNumbers = (1..$attempts.Count) -join ','
    $everyAttemptTagged = @($attempts | Where-Object { $null -eq $_.Tags['outbox.outcome'] -or $null -eq $_.Tags['outbox.wait_seconds'] }).Count -eq 0
    $retriesWait = @($attempts | Select-Object -SkipLast 1 | Where-Object { $_.Tags['outbox.outcome'] -ne 'Retry' -or [double]$_.Tags['outbox.wait_seconds'] -le 0 }).Count -eq 0
    $lastSent = $attempts.Count -gt 0 -and $attempts[-1].Tags['outbox.outcome'] -eq 'Sent'
    Write-Result ($attempts.Count -ge 3 -and $numbered -eq $expectedNumbers -and $everyAttemptTagged -and $retriesWait -and $lastSent) `
        "$($attempts.Count) deneme ayrı span; her birinde numara, sonuç ve bekleme süresi var, sonuncusu Gönderildi ($number)"
    Write-Host "  Ekran görüntüsü: $JaegerUrl/trace/$($trace.TraceId)" -ForegroundColor DarkGray
}
finally { Restart-Simulator }
