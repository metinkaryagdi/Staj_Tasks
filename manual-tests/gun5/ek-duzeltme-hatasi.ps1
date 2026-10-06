# Gün 5 - Ek test: düzeltmesi hata veren fatura. İki faturanın düzeltmesi gerekiyor; birinin güncellemesi veritabanında
# trigger ile hataya düşürülüyor. Mutabakat diğerini düzeltir, hatalı olanı nedeniyle birlikte Raporlandı bulgusu olarak
# kaydeder ve fatura değişmez; trigger kalkınca sonraki çalışma onu da düzeltir. ~2 dk.
. "$PSScriptRoot\_common.ps1"

$dropTrigger = "DROP TRIGGER IF EXISTS trg_duzeltme_hatasi ON invoices; DROP FUNCTION IF EXISTS duzeltme_hatasi();"
trap { Write-Host "Hata: $_ - trigger kaldırılıyor, simülatör ve servis varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Invoke-ServiceSql $dropTrigger | Out-Null; Restart-Simulator; Restart-InvoiceService } catch { }; break }

Write-Title 'Ek test) Düzeltmesi hata veren fatura nedeniyle birlikte bulgu olarak kaydediliyor'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
Restart-Simulator (Get-SimSettings)
Restart-InvoiceService

$numbers = @(New-Invoices 2)
$bad = $numbers[0]; $good = $numbers[1]
$list = InList $numbers
Wait-InvoicesIn $numbers @('Onaylandı', 'Reddedildi') 180 'kesin durumda' | Out-Null
Wait-EventsDone $numbers 120 | Out-Null

$erpDecision = @{}
foreach ($row in @(Get-ErpRows "SELECT invoice_number, event_type FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'Normal' AND event_type <> 'invoice.received' ORDER BY 1;")) {
    $parts = $row -split '\|'
    $erpDecision[$parts[0]] = if ($parts[1] -eq 'invoice.approved') { 'Onaylandı' } else { 'Reddedildi' }
}

Write-Step "İki fatura da Gönderildi'ye geri alınıyor (servis kararı öğrenmemiş gibi), $bad için güncellemeyi hataya düşüren trigger kuruluyor"
# SQL argüman olarak verilir (stdin PowerShell 5.1'de Türkçe karakterleri bozar).
$old = "now() - interval '10 minutes'"
Invoke-ServiceSql ("UPDATE invoices SET status = 'Gönderildi', reject_reason = NULL, updated_at = $old WHERE invoice_number IN ($list); " +
                   "CREATE FUNCTION duzeltme_hatasi() RETURNS trigger AS 'BEGIN IF NEW.invoice_number = ''$bad'' THEN RAISE EXCEPTION ''elle verilen hata''; END IF; RETURN NEW; END;' LANGUAGE plpgsql; " +
                   "CREATE TRIGGER trg_duzeltme_hatasi BEFORE UPDATE ON invoices FOR EACH ROW EXECUTE FUNCTION duzeltme_hatasi();") | Out-Null
Show-ServiceQuery "SELECT invoice_number, status, erp_reference FROM invoices WHERE invoice_number IN ($list) ORDER BY 1;"

Write-Step '1. mutabakat elle başlatılıyor (trigger açık)'
$run1 = Invoke-Reconciliation
$id1 = $run1.run.id
Write-Host "  çalışma ${id1}: $($run1.run.status)"
Write-DbHeader 'Fatura Servisi' '1. çalışma: bulgular ve faturaların hâli'
Show-Run $id1
Show-Findings $id1 "AND invoice_number IN ($list)"
Show-ServiceQuery "SELECT invoice_number, status FROM invoices WHERE invoice_number IN ($list) ORDER BY 1;"

$f1 = @{}
foreach ($row in @(Get-ServiceRows "SELECT invoice_number, finding_type, action, details FROM reconciliation_findings WHERE run_id = $id1 AND invoice_number IN ($list) ORDER BY 1;")) {
    $parts = $row -split '\|', 4
    $f1[$parts[0]] = $parts
}
$status1 = @{}
foreach ($row in @(Get-ServiceRows "SELECT invoice_number, status FROM invoices WHERE invoice_number IN ($list) ORDER BY 1;")) {
    $parts = $row -split '\|'
    $status1[$parts[0]] = $parts[1]
}
$counts1 = @(Get-ServiceRows "SELECT fixed_count, reported_count FROM reconciliation_runs WHERE id = $id1;")[0]

Check (Write-DbVerdict 'çalışma Tamamlandı (bir düzeltmenin hatası çalışmayı düşürmez)' $run1.run.status ($run1.run.status -eq 'Tamamlandı'))
Check (Write-DbVerdict "hatalı fatura: Takılı Fatura / Raporlandı, nedeni ayrıntıda" "$($f1[$bad][1])|$($f1[$bad][2]) / $($f1[$bad][3])" `
    ($f1[$bad][1] -eq 'Takılı Fatura' -and $f1[$bad][2] -eq 'Raporlandı' -and $f1[$bad][3] -like 'Düzeltme uygulanamadı:*elle verilen hata*'))
Check (Write-DbVerdict 'hatalı fatura değişmedi (Gönderildi)' $status1[$bad] ($status1[$bad] -eq 'Gönderildi'))
Check (Write-DbVerdict "diğer fatura düzeltildi: Takılı Fatura / Düzeltildi, ERP'nin kararı ($($erpDecision[$good]))" "$($f1[$good][1])|$($f1[$good][2]) / $($status1[$good])" `
    ($f1[$good][1] -eq 'Takılı Fatura' -and $f1[$good][2] -eq 'Düzeltildi' -and $status1[$good] -eq $erpDecision[$good]))
Check (Write-DbVerdict 'çalışmanın sayıları: düzeltilen ve raporlanan bu iki faturayı içeriyor (>= 1 / >= 1)' $counts1 `
    ([int]($counts1 -split '\|')[0] -ge 1 -and [int]($counts1 -split '\|')[1] -ge 1))

Write-Step 'Trigger kaldırılıyor, 2. mutabakat başlatılıyor: hatalı fatura bu sefer düzelmeli'
Invoke-ServiceSql $dropTrigger | Out-Null
$run2 = Invoke-Reconciliation
$id2 = $run2.run.id
Write-Host "  çalışma ${id2}: $($run2.run.status)"
Write-DbHeader 'Fatura Servisi' '2. çalışma: bulgular ve faturaların hâli'
Show-Findings $id2 "AND invoice_number IN ($list)"
Show-ServiceQuery "SELECT invoice_number, status FROM invoices WHERE invoice_number IN ($list) ORDER BY 1;"
$f2 = @(Get-ServiceRows "SELECT finding_type, action FROM reconciliation_findings WHERE run_id = $id2 AND invoice_number = '$bad';")
$badStatus2 = @(Get-ServiceRows "SELECT status FROM invoices WHERE invoice_number = '$bad';")[0]
Check (Write-DbVerdict "sonraki çalışma hatalı faturayı düzeltti: Takılı Fatura / Düzeltildi, $($erpDecision[$bad])" "$($f2 -join ', ') / $badStatus2" `
    ($f2.Count -eq 1 -and $f2[0] -eq 'Takılı Fatura|Düzeltildi' -and $badStatus2 -eq $erpDecision[$bad]))

Restart-Simulator
Write-Result $allPassed 'Düzeltmesi hata veren fatura nedeniyle bulgu olarak kaydedildi, sonraki çalışma düzeltti'
