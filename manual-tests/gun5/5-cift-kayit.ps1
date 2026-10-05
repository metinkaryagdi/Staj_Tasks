# Gün 5 - Kontrol listesi 5: IdempotentInvoices kapalıyken (varsayılan) bir faturayı simülatöre elle ikinci kez gönder.
# Mutabakat çift kayıt olarak raporlar; iki tarafta da hiçbir şey değişmez. ~1 dk.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: $_ - simülatör ve servis varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Restart-Simulator; Restart-InvoiceService } catch { }; break }

Write-Title 'Kontrol listesi 5) IdempotentInvoices kapalıyken ikinci gönderim: çift kayıt olarak raporlanıyor'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
Restart-Simulator (Get-SimSettings -NoEvents)
Restart-InvoiceService
$number = New-SentInvoice
$serviceBefore = (@(Get-ServiceRows "SELECT status, amount, erp_reference, updated_at FROM invoices WHERE invoice_number = '$number';") -join ';')

$row = @(Get-ServiceRows "SELECT customer_code, amount, currency, invoice_date FROM invoices WHERE invoice_number = '$number';")[0] -split '\|'
$json = '{"invoiceNumber":"' + $number + '","customerCode":"' + $row[0] + '","amount":' + $row[1] + ',"currency":"' + $row[2] + '","invoiceDate":"' + $row[3] + '"}'
Write-Step "$number faturası simülatöre elle ikinci kez gönderiliyor"
$r = Send-Json "$SimulatorUrl/api/v1/invoices" $json
Write-Host "  HTTP $($r.Status)"
Show-ErpQuery "SELECT invoice_number, erp_reference, amount FROM invoices WHERE invoice_number = '$number' ORDER BY id;"
$erpRecords = Count-Erp "SELECT count(*) FROM invoices WHERE invoice_number = '$number';"

Write-Step 'Mutabakat elle başlatılıyor'
$run = Invoke-Reconciliation
$id = $run.run.id
Write-Host "  çalışma ${id}: $($run.run.status)"

Write-DbHeader 'Fatura Servisi' 'Bulgu ve faturanın kendisi'
Show-Findings $id "AND invoice_number = '$number'"
$finding = @(Get-ServiceRows "SELECT finding_type, action FROM reconciliation_findings WHERE run_id = $id AND invoice_number = '$number';")
$serviceAfter = (@(Get-ServiceRows "SELECT status, amount, erp_reference, updated_at FROM invoices WHERE invoice_number = '$number';") -join ';')
$erpAfter = Count-Erp "SELECT count(*) FROM invoices WHERE invoice_number = '$number';"

Check (Write-DbVerdict 'ikinci gönderim 202, simülatörde 2 kayıt' "HTTP $($r.Status), $erpRecords kayıt" ($r.Status -eq 202 -and $erpRecords -eq 2))
Check (Write-DbVerdict 'bulgu: ERP Çift Kayıt / Raporlandı' ($finding -join ', ') ($finding.Count -eq 1 -and $finding[0] -eq 'ERP Çift Kayıt|Raporlandı'))
Check (Write-DbVerdict 'serviste fatura aynı' $serviceAfter ($serviceAfter -eq $serviceBefore))
Check (Write-DbVerdict 'simülatörde hâlâ 2 kayıt (silinmedi, birleştirilmedi)' "$erpAfter" ($erpAfter -eq 2))

# --- Çift kayıtlı fatura Başarısız olsa da yalnızca raporlanır -------------------------------------------------------------
Write-Step "$number serviste Başarısız yapılıyor (erp_reference boş); ERP'de hâlâ 2 kaydı var"
Invoke-ServiceSql ("UPDATE invoices SET status = 'Başarısız', erp_reference = NULL, last_error = 'elle bozuldu' WHERE invoice_number = '$number'; " +
                   "UPDATE erp_outbox SET status = 'Başarısız' WHERE invoice_number = '$number';") | Out-Null
$stateSql = "SELECT i.status, coalesce(i.erp_reference, ''), o.status FROM invoices i JOIN erp_outbox o ON o.invoice_number = i.invoice_number WHERE i.invoice_number = '$number';"
$failedBefore = (@(Get-ServiceRows $stateSql) -join ';')
$run2 = Invoke-Reconciliation
$id2 = $run2.run.id
Write-Host "  çalışma ${id2}: $($run2.run.status)"
Write-DbHeader 'Fatura Servisi' 'Çift kayıtlı Başarısız fatura: bulgu ve faturanın hâli'
Show-Findings $id2 "AND invoice_number = '$number'"
Show-ServiceQuery $stateSql
$finding2 = @(Get-ServiceRows "SELECT finding_type, action FROM reconciliation_findings WHERE run_id = $id2 AND invoice_number = '$number' ORDER BY id;")
$failedAfter = (@(Get-ServiceRows $stateSql) -join ';')
Check (Write-DbVerdict 'yalnızca ERP Çift Kayıt / Raporlandı (geri getirme ya da düzeltme bulgusu yok)' ($finding2 -join ', ') `
    ($finding2.Count -eq 1 -and $finding2[0] -eq 'ERP Çift Kayıt|Raporlandı'))
Check (Write-DbVerdict 'fatura ve erp_outbox değişmedi (Başarısız, referans boş)' $failedAfter ($failedAfter -eq $failedBefore))

Restart-Simulator
Write-Result $allPassed 'çift kayıt raporlandı, iki tarafta hiçbir şey değişmedi'
