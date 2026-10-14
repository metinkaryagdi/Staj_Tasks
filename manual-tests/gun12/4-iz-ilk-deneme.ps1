# Kontrol listesi 3: ilk denemede gönderilen bir faturanın izi; yolculuğun bütün adımları tek trace'te görünüyor.
#   .\manual-tests\gun12\4-iz-ilk-deneme.ps1
# Simülatör her isteği kabul eder (Success %100), haber sorunları kapalıdır: iz yalnızca normal yolu gösterir. Fatura
# kararını alınca iz Jaeger'dan okunur, adımlar tek tek aranır; ekran görüntüsü yazılan Jaeger adresinden alınır.
. "$PSScriptRoot\_common.ps1"

Write-Title 'Kontrol listesi 3: ilk denemede gönderilen faturanın izi'
Restart-Simulator (Get-SimSettings 'Success')

Write-Step 'Fatura oluşturuluyor'
$number = (New-ServiceInvoice).InvoiceNumber
Write-Host "  $number"
Wait-InvoicesIn @($number) @('Onaylandı', 'Reddedildi') 120 'karar aldı' | Out-Null
Wait-EventsDone @($number) 60 | Out-Null

Write-Step "Jaeger'daki iz"
$trace = Get-InvoiceTrace $number
Show-Trace $trace 'gun12-4-iz-ilk-deneme.txt'

function Find([string]$Name, [string]$Service, [scriptblock]$Where = { $true }) {
    @($trace.Spans | Where-Object { $_.Name -eq $Name -and $_.Service -eq $Service } | Where-Object $Where)
}
$attempts = @(Find 'outbox.attempt' 'invoice-service')
$sends = @(Find 'webhook.send' 'erp-simulator')
$received = @(Find 'POST /api/v1/erp-webhooks' 'invoice-service')
$checks = [ordered]@{
    'Faturanın oluşturulması (POST /api/v1/invoices)' = @(Find 'POST /api/v1/invoices/' 'invoice-service').Count -eq 1
    'Tek deneme, sonucu Gönderildi (Sent)' = $attempts.Count -eq 1 -and $attempts[0].Tags['outbox.outcome'] -eq 'Sent' -and $attempts[0].Tags['outbox.attempt'] -eq 1
    "Worker'ın kaydı alması (outbox.claimed, toplu almaya link)" = @(Find 'outbox.claimed' 'invoice-service' { @($_.Links).Count -eq 1 }).Count -eq 1
    'Hız sınırında bekleme (erp.pace_wait)' = @(Find 'erp.pace_wait' 'invoice-service').Count -eq 1
    'Simülatördeki işlem (simulator.outcome=Success)' = @(Find 'POST /api/v1/invoices/' 'erp-simulator' { $_.Tags['simulator.outcome'] -eq 'Success' }).Count -eq 1
    'Simülatörden iki haber (webhook.send, Delivered)' = $sends.Count -eq 2 -and @($sends | Where-Object { $_.Tags['webhook.outcome'] -eq 'Delivered' }).Count -eq 2
    "Haberler servise ulaşıp işlendi (erp_event.status=İşlendi)" = $received.Count -eq 2 -and @($received | Where-Object { $_.Tags['erp_event.status'] -eq 'İşlendi' }).Count -eq 2
}
Write-Step 'Adımlar'
$checks.GetEnumerator() | ForEach-Object { Write-Host ("  [{0}] {1}" -f $(if ($_.Value) { 'OK' } else { 'YOK' }), $_.Key) }
Write-Result (@($checks.Values | Where-Object { -not $_ }).Count -eq 0) "Yolculuğun bütün adımları tek trace'te ($number)"
Write-Host "  Ekran görüntüsü: $JaegerUrl/trace/$($trace.TraceId)" -ForegroundColor DarkGray
Restart-Simulator
