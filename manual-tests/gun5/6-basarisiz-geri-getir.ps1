# Gün 5 - Kontrol listesi 6: servisin veritabanında Gönderildi olan bir faturayı elle Başarısız yap, erp_reference'ı boşalt.
# Mutabakat faturayı ERP'deki referansla Gönderildi'ye geri getirir. ~1 dk.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: $_ - simülatör ve servis varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Restart-Simulator; Restart-InvoiceService } catch { }; break }

Write-Title 'Kontrol listesi 6) Serviste elle Başarısız yapılan fatura: ERP''deki referansla geri geliyor'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
Restart-Simulator (Get-SimSettings -NoEvents)
Restart-InvoiceService
$number = New-SentInvoice
$erpReference = Get-SqlScalar "SELECT erp_reference FROM invoices WHERE invoice_number = '$number' ORDER BY id LIMIT 1;"

Write-Step "$number faturası serviste elle Başarısız yapılıyor, erp_reference boşaltılıyor (erp_outbox kaydı da Başarısız)"
# SQL argüman olarak verilir (stdin PowerShell 5.1'de Türkçe karakterleri bozar).
Invoke-ServiceSql ("UPDATE invoices SET status = 'Başarısız', erp_reference = NULL, last_error = 'elle bozuldu' WHERE invoice_number = '$number'; " +
                   "UPDATE erp_outbox SET status = 'Başarısız' WHERE invoice_number = '$number';") | Out-Null
if ((Count-Service "SELECT count(*) FROM invoices i JOIN erp_outbox o ON o.invoice_number = i.invoice_number WHERE i.invoice_number = '$number' AND i.status = 'Başarısız' AND o.status = 'Başarısız' AND i.erp_reference IS NULL;") -ne 1) {
    throw 'Fatura ve erp_outbox kaydı elle Başarısız yapılamadı.'
}
Show-ServiceQuery ("SELECT i.invoice_number, i.status, i.erp_reference, o.status AS outbox FROM invoices i " +
                   "JOIN erp_outbox o ON o.invoice_number = i.invoice_number WHERE i.invoice_number = '$number';")
Show-ErpQuery "SELECT invoice_number, erp_reference FROM invoices WHERE invoice_number = '$number';"

Write-Step 'Mutabakat elle başlatılıyor'
$run = Invoke-Reconciliation
$id = $run.run.id
Write-Host "  çalışma ${id}: $($run.run.status)"

Write-DbHeader 'Fatura Servisi' 'Bulgu ve faturanın şimdiki hâli'
Show-Findings $id "AND invoice_number = '$number'"
Show-ServiceQuery ("SELECT i.invoice_number, i.status, i.erp_reference, i.last_error, o.status AS outbox FROM invoices i " +
                   "JOIN erp_outbox o ON o.invoice_number = i.invoice_number WHERE i.invoice_number = '$number';")
$finding = @(Get-ServiceRows "SELECT finding_type, action FROM reconciliation_findings WHERE run_id = $id AND invoice_number = '$number';")
$after = @(Get-ServiceRows "SELECT i.status, coalesce(i.erp_reference, ''), coalesce(i.last_error, ''), o.status FROM invoices i JOIN erp_outbox o ON o.invoice_number = i.invoice_number WHERE i.invoice_number = '$number';")[0] -split '\|'

Check (Write-DbVerdict 'bulgu: Başarısız Ama ERP Kayıtlı / Düzeltildi' ($finding -join ', ') ($finding.Count -eq 1 -and $finding[0] -eq 'Başarısız Ama ERP Kayıtlı|Düzeltildi'))
Check (Write-DbVerdict "fatura Gönderildi, erp_reference = simülatördeki $erpReference, last_error boş" ($after[0..2] -join ' / ') `
    ($after[0] -eq 'Gönderildi' -and $after[1] -eq $erpReference -and $after[2] -eq ''))
Check (Write-DbVerdict 'erp_outbox kaydı Tamamlandı (fatura ile tutarlı)' $after[3] ($after[3] -eq 'Tamamlandı'))
Check (Write-DbVerdict 'simülatörde hâlâ tek kayıt' (Count-Erp "SELECT count(*) FROM invoices WHERE invoice_number = '$number';") ((Count-Erp "SELECT count(*) FROM invoices WHERE invoice_number = '$number';") -eq 1))

Restart-Simulator
Write-Result $allPassed 'Başarısız yapılan fatura ERP''deki referansla Gönderildi''ye geri getirildi'
