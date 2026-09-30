# Gün 2 - Madde 2: Simülatörün hata oranları 0 iken 100 fatura.
# Beklenen: serviste 100 kayıt, hepsi Gönderildi; simülatörde 100 kayıt; erp_reference değerleri iki tarafta aynı.
param([int]$Count = 100)
. "$PSScriptRoot\_common.ps1"

Write-Title "2) Hata oranları 0 -> $Count fatura: serviste $Count Gönderildi, simülatörde $Count kayıt, referanslar aynı"

Restart-Simulator @{
    Simulator__Rates__Success       = 100
    Simulator__Rates__Busy          = 0
    Simulator__Rates__ServerError   = 0
    Simulator__Rates__SaveThenError = 0
    Simulator__Rates__LateResponse  = 0
}
Wait-Service

Write-Step "$Count fatura Fatura Servisi'ne gönderiliyor (POST $ServiceUrl/api/v1/invoices)"
$results = foreach ($i in 1..$Count) { $r = New-ServiceInvoice; Write-ServiceResult $r; $r }
$from = $results[0].InvoiceNumber
$to = $results[-1].InvoiceNumber

Write-Step "Servis veritabanı ($from .. $to)"
Invoke-ServiceSql ("SELECT status, count(*) AS kayit, count(DISTINCT erp_reference) AS farkli_referans, " +
    "min(invoice_number) AS ilk, max(invoice_number) AS son FROM invoices " +
    "WHERE invoice_number BETWEEN '$from' AND '$to' GROUP BY status;") | Out-Host

Write-Step 'Karşılaştırma script''i'
$c = Compare-Invoices -From $from -To $to

$passed = $c.Total -eq $Count -and $c.SentFound -eq $Count -and $c.SimulatorRecords -eq $Count -and
    $c.ReferenceMatches -eq $Count
Write-Result $passed ("serviste $($c.Total) kayıt, $($c.SentFound + $c.SentMissing) Gönderildi; simülatörde " +
    "$($c.SimulatorRecords) kayıt; erp_reference aynı: $($c.ReferenceMatches)/$Count")

Restart-Simulator
