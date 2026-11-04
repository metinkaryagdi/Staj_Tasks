# Kontrol listesinin ötesindeki iki sınama. Çıktı manual-tests\output\gun23\e-ek-sinama.txt.
#   a) Serviste İptal Edildi, ERP faturayı reddetmiş: mutabakat yalnız raporlar, fatura ve iptal değişmez.
#   b) Ekrandaki başarısız iptal için hazırlık: fatura Onaylandı olur, ERP durdurulur; ekrandaki adımlar elle yapılır, ERP'yi açmak için
#      docker compose start erp-simulator.
#   .\manual-tests\gun23\4-ek-sinama.ps1
. "$PSScriptRoot\_common.ps1"

New-Report 'e-ek-sinama'
Write-Title 'Ek sınama: ERP''nin reddettiği fatura ve ekrandaki başarısız iptal'
Write-Line "Koşu: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

Write-Line ''
Write-Line 'a) Serviste İptal Edildi, ERP faturayı reddetmiş'
Set-Erp @{ Success = 100 } @{ 'Webhooks__ApprovalRate' = 0; 'Webhooks__SecondEventMinSeconds' = 15; 'Webhooks__SecondEventMaxSeconds' = 15 }
$n = New-Invoice
Wait-Until { (Get-InvoiceStatus $n) -in 'Gönderildi', 'İşleme Alındı' } 30 "$n ERP'ye ulaştı"
$reference = Invoke-InvoiceSql "SELECT erp_reference FROM invoices WHERE invoice_number = '$n'"
$r = Send-SignedEvent "gun23-ek-$(Get-Random)" 'invoice.cancelled' $n $reference
Write-Line "  Elle imzalı iptal haberi: HTTP $($r.Status), fatura $(Get-InvoiceStatus $n)"
Wait-Until { (Get-ErpDecision $n) -eq 'rejected' } 40 'ERP faturayı reddetti'
Start-Sleep -Seconds 3
Check ((Get-InvoiceStatus $n) -eq 'İptal Edildi') "Red haberinden sonra servisteki durum: $(Get-InvoiceStatus $n)"
Show-Events $n
$state = Invoke-Reconciliation
Check ($state.status -eq 'Tamamlandı') "Mutabakat $($state.id): $($state.status), düzeltilen $($state.fixedCount), raporlanan $($state.reportedCount)"
Show-Rows 'Servis (reconciliation_findings):' "SELECT finding_type, action, details FROM reconciliation_findings WHERE invoice_number = '$n' ORDER BY id"
$action = Invoke-InvoiceSql "SELECT action FROM reconciliation_findings WHERE invoice_number = '$n' AND finding_type = 'Serviste İptal Edilmiş'"
Check ($action -eq 'Raporlandı') "Bulgunun eylemi: $action"
$row = Invoke-InvoiceSql "SELECT count(*) FROM erp_outbox WHERE invoice_number = '$n' AND kind = 'İptal'"
Check ($row -eq '0') "Kuyruğa iptal satırı girmedi: $row"
Check ((Get-InvoiceStatus $n) -eq 'İptal Edildi') "Son durum: $(Get-InvoiceStatus $n)"

Write-Line ''
Write-Line 'b) Ekrandaki başarısız iptal için hazırlık'
Set-Erp @{ Success = 100 }
$n2 = New-Invoice
Wait-Until { (Get-InvoiceStatus $n2) -eq 'Onaylandı' } 60 "$n2 Onaylandı oldu"
Push-Location $RepoRoot
try { docker compose stop erp-simulator 2>&1 | Out-Null } finally { Pop-Location }
Write-Line "  ERP durduruldu $(Get-Date -Format 'HH:mm:ss')"
Write-Output "FATURA=$n2"
Save-Report
