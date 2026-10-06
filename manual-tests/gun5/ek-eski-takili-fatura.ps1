# Gün 5 - Ek test: son 24 saatin dışına kaymış, durumu kesinleşmemiş faturalar. Mutabakat bunları yaşlarına bakmadan
# kontrol eder: takılı fatura ERP'nin kararını alır, Başarısız ama ERP'de kayıtlı fatura geri gelir; kesinleşmiş eski fatura
# kontrol edilmez. ~2 dk.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: $_ - simülatör ve servis varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Restart-Simulator; Restart-InvoiceService } catch { }; break }

Write-Title 'Ek test) 24 saatin dışındaki kesinleşmemiş faturalar mutabakatta yine kontrol ediliyor'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
Restart-Simulator (Get-SimSettings)
Restart-InvoiceService

$numbers = @(New-Invoices 3)
$stuck = $numbers[0]; $failed = $numbers[1]; $final = $numbers[2]
$list = InList $numbers
Wait-InvoicesIn $numbers @('Onaylandı', 'Reddedildi') 180 'kesin durumda' | Out-Null
Wait-EventsDone $numbers 120 | Out-Null

# ERP'nin her fatura için verdiği karar ve referans (servis bunları değiştirmeden önce).
$erpDecision = @{}
foreach ($row in @(Get-ErpRows "SELECT invoice_number, event_type FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'Normal' AND event_type <> 'invoice.received' ORDER BY 1;")) {
    $parts = $row -split '\|'
    $erpDecision[$parts[0]] = if ($parts[1] -eq 'invoice.approved') { 'Onaylandı' } else { 'Reddedildi' }
}
$erpReference = @{}
foreach ($row in @(Get-ErpRows "SELECT invoice_number, erp_reference FROM invoices WHERE invoice_number IN ($list) ORDER BY 1;")) {
    $parts = $row -split '\|'
    $erpReference[$parts[0]] = $parts[1]
}

Write-Step 'Üç fatura 3 gün öncesine alınıyor: biri Gönderildi (takılı), biri Başarısız (referansı boş), biri kesin durumda kalıyor'
# SQL argüman olarak verilir (stdin PowerShell 5.1'de Türkçe karakterleri bozar).
$old = "now() - interval '3 days'"
Invoke-ServiceSql ("UPDATE invoices SET status = 'Gönderildi', reject_reason = NULL, created_at = $old, updated_at = $old WHERE invoice_number = '$stuck'; " +
                   "UPDATE invoices SET status = 'Başarısız', erp_reference = NULL, reject_reason = NULL, last_error = 'elle bozuldu', created_at = $old, updated_at = $old WHERE invoice_number = '$failed'; " +
                   "UPDATE erp_outbox SET status = 'Başarısız' WHERE invoice_number = '$failed'; " +
                   "UPDATE invoices SET created_at = $old, updated_at = $old WHERE invoice_number = '$final';") | Out-Null
$beforeSql = "SELECT invoice_number, status, erp_reference, to_char(created_at, 'YYYY-MM-DD HH24:MI') AS oluşturuldu FROM invoices WHERE invoice_number IN ($list) ORDER BY 1;"
Show-ServiceQuery $beforeSql
Show-ErpQuery "SELECT invoice_number, erp_reference FROM invoices WHERE invoice_number IN ($list) ORDER BY 1;"

Write-DbHeader 'Fatura Servisi' 'Üç fatura da mutabakatın 24 saatlik penceresinin dışında'
Check (Write-DbVerdict 'üç faturanın oluşturulma zamanı 24 saatten eski' (Count-Service "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND created_at < now() - interval '24 hours';") `
    ((Count-Service "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND created_at < now() - interval '24 hours';") -eq 3))

Write-Step 'Mutabakat elle başlatılıyor'
$run = Invoke-Reconciliation
$id = $run.run.id
Write-Host "  çalışma ${id}: $($run.run.status)"

Write-DbHeader 'Fatura Servisi' 'Bulgular ve faturaların şimdiki hâli'
Show-Findings $id "AND invoice_number IN ($list)"
Show-ServiceQuery "SELECT invoice_number, status, erp_reference, last_error FROM invoices WHERE invoice_number IN ($list) ORDER BY 1;"

$findings = @{}
foreach ($row in @(Get-ServiceRows "SELECT invoice_number, finding_type, action FROM reconciliation_findings WHERE run_id = $id AND invoice_number IN ($list) ORDER BY 1;")) {
    $parts = $row -split '\|'
    $findings[$parts[0]] = "$($parts[1])|$($parts[2])"
}
$after = @{}
foreach ($row in @(Get-ServiceRows "SELECT invoice_number, status, coalesce(erp_reference, '') FROM invoices WHERE invoice_number IN ($list) ORDER BY 1;")) {
    $parts = $row -split '\|'
    $after[$parts[0]] = "$($parts[1])|$($parts[2])"
}

Check (Write-DbVerdict 'çalışma Tamamlandı' $run.run.status ($run.run.status -eq 'Tamamlandı'))
Check (Write-DbVerdict "Gönderildi'de takılı eski fatura: Takılı Fatura / Düzeltildi" $findings[$stuck] ($findings[$stuck] -eq 'Takılı Fatura|Düzeltildi'))
Check (Write-DbVerdict "  ... ve ERP'nin kararını aldı ($($erpDecision[$stuck]))" $after[$stuck] ($after[$stuck] -eq "$($erpDecision[$stuck])|$($erpReference[$stuck])"))
Check (Write-DbVerdict 'Başarısız eski fatura: Başarısız Ama ERP Kayıtlı / Düzeltildi' $findings[$failed] ($findings[$failed] -eq 'Başarısız Ama ERP Kayıtlı|Düzeltildi'))
Check (Write-DbVerdict "  ... ERP'deki referansla geri geldi ve kararı aldı ($($erpDecision[$failed]))" $after[$failed] ($after[$failed] -eq "$($erpDecision[$failed])|$($erpReference[$failed])"))
Check (Write-DbVerdict 'kesin durumdaki eski fatura: bulgu yok, değişmedi' "$(if ($findings.ContainsKey($final)) { $findings[$final] } else { 'bulgu yok' }) / $($after[$final])" `
    (-not $findings.ContainsKey($final) -and $after[$final] -eq "$($erpDecision[$final])|$($erpReference[$final])"))

Restart-Simulator
Write-Result $allPassed '24 saatin dışındaki takılı fatura karar aldı, Başarısız fatura geri geldi, kesinleşmiş eski fatura kontrol edilmedi'
