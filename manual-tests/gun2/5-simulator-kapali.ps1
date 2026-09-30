# Gün 2 - Madde 5: Simülatörü durdur ve bir fatura oluştur.
# İstek ne döndü, fatura invoices tablosunda var mı, status ne?
. "$PSScriptRoot\_common.ps1"

Write-Title '5) Simülatör kapalıyken fatura oluştur'
Wait-Service

Write-Step 'docker compose stop erp-simulator'
Invoke-Compose @('stop', 'erp-simulator')

Write-Step "POST $ServiceUrl/api/v1/invoices"
$r = New-ServiceInvoice
Write-Host "  HTTP durum: $($r.HttpStatus)  süre: $($r.Seconds)s"
Write-Host "  Gövde: $($r.Body)"

Write-Step 'Servis veritabanı'
Invoke-ServiceSql ("SELECT invoice_number, status, erp_reference, last_error, send_attempt_count, created_at, updated_at " +
    "FROM invoices WHERE invoice_number = '$($r.InvoiceNumber)';") | Out-Host
$row = @(Get-ServiceRows "SELECT status FROM invoices WHERE invoice_number = '$($r.InvoiceNumber)';")

Write-Result ($r.HttpStatus -eq 201 -and $row -and $row[0] -eq 'Başarısız') `
    "istek $($r.HttpStatus) döndü, fatura tabloda $(if ($row) { "var, status=$($row[0])" } else { 'YOK' })"

Restart-Simulator
