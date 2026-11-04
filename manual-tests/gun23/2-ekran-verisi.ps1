# Ekran kontrolü (kontrol listesi 6) için faturalar: biri Onaylandı, biri Reddedildi. Numaraları yazar; ekrandaki adımlar elle yapılır.
#   .\manual-tests\gun23\2-ekran-verisi.ps1
. "$PSScriptRoot\_common.ps1"

Set-Erp @{ Success = 100 } @{ 'Webhooks__ApprovalRate' = 0 }
$rejected = New-Invoice
Wait-Until { (Get-InvoiceStatus $rejected) -eq 'Reddedildi' } 60 "$rejected Reddedildi oldu"

Set-Erp @{ Success = 100 }
$approved = New-Invoice
Wait-Until { (Get-InvoiceStatus $approved) -eq 'Onaylandı' } 60 "$approved Onaylandı oldu"

Write-Output "ONAYLANDI=$approved"
Write-Output "REDDEDILDI=$rejected"
