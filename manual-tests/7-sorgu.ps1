# Test 7: GET ile kayıtlı bir fatura sorgulandığında referans numarası döner, olmayan bir fatura için 404 döner.
# -InvoiceNumber verilirse o fatura sorgulanır (ör. diğer testlerde oluşan bir numara).
# Verilmezse önce hata oranları 0 iken yeni bir fatura kaydedilir, sonra o sorgulanır.
param([string]$InvoiceNumber, [string]$MissingInvoiceNumber)
. "$PSScriptRoot\_common.ps1"

Write-Title '7) GET: kayıtlı fatura -> 200 + ERP referansı, olmayan fatura -> 404'

$expectedReference = $null
if (-not $InvoiceNumber) {
    Restart-Simulator @{
        Simulator__Rates__Busy          = 0
        Simulator__Rates__ServerError   = 0
        Simulator__Rates__SaveThenError = 0
        Simulator__Rates__LateResponse  = 0
    }
    $InvoiceNumber = (New-Prefix 'T7') + '1'
    Write-Step "Sorgulanacak fatura kaydediliyor: $InvoiceNumber"
    $created = Send-Invoice $InvoiceNumber
    Write-Response $created
    $expectedReference = $created.ErpReference
}
if (-not $MissingInvoiceNumber) { $MissingInvoiceNumber = 'YOK-' + (Get-Date -Format 'yyyyMMddHHmmss') }

Write-Step "GET $BaseUrl/api/v1/invoices/$InvoiceNumber"
$found = Get-Invoice $InvoiceNumber
Write-Host "  Durum: $($found.Status)"
Write-Host "  Gövde: $($found.Body)"
$reference = if ($found.Body -match '"erpReference":"([^"]+)"') { $Matches[1] } else { '' }

Write-Step "GET $BaseUrl/api/v1/invoices/$MissingInvoiceNumber"
$missing = Get-Invoice $MissingInvoiceNumber
Write-Host "  Durum: $($missing.Status)"
Write-Host "  Gövde: $($missing.Body)"

Show-DbRows $InvoiceNumber

$referenceOk = $reference -like 'ERP-*' -and (-not $expectedReference -or $reference -eq $expectedReference)
Write-Result ($found.Status -eq 200 -and $referenceOk -and $missing.Status -eq 404) `
    "kayıtlı: $($found.Status) (erpReference=$reference), olmayan: $($missing.Status)"

if ($expectedReference) { Restart-Simulator }
