# Gün 2 - Madde 5: Simülatörü durdur ve bir fatura oluştur.
# İstek ne döndü, fatura invoices tablosunda var mı, status ne?
. "$PSScriptRoot\_common.ps1"

Write-Title '5) Simülatör kapalıyken fatura oluştur'
Wait-Service

Write-Step 'docker compose stop erp-simulator  (erp-db açık kalır)'
Invoke-Compose @('stop', 'erp-simulator')

Write-Step "POST $ServiceUrl/api/v1/invoices"
$r = New-ServiceInvoice
Write-Host "  HTTP durum: $($r.HttpStatus)  süre: $($r.Seconds)s"
Write-Host "  Gövde: $($r.Body)"

$dbOk = Test-DbErpDown -Title 'Madde 5: fatura serviste var, simülatörde yok' -InvoiceNumber $r.InvoiceNumber

Write-Result ($r.HttpStatus -eq 201 -and $r.Status -eq 'Başarısız' -and $dbOk) `
    ("istek $($r.HttpStatus) döndü, cevaptaki status: $($r.Status); " +
     "veritabanı kontrolü: $(if ($dbOk) { 'geçti' } else { 'KALDI' })")

Restart-Simulator
