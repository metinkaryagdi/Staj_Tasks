# Gün 5 - Kontrol listesi 2: varsayılan oranlarla 500 fatura gönder, haberler bitince mutabakatı çalıştır.
# Gönderildi ya da İşleme Alındı'da kalan fatura sayısı 0 olmalı; mutabakatın düzelttiği fatura sayısı, simülatörün karar
# haberini göndermediği fatura sayısına eşit olmalı. ~6-8 dk.
#
# Zamanlanmış mutabakat araya girmesin diye aralık varsayılanda (60 dk) bırakılır. Önce bir mutabakat çalıştırılır:
# daha önceki testlerden kalan takılı faturalar bu 500'ün sayımına karışmasın.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: simülatör ve servis varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Restart-Simulator; Restart-InvoiceService } catch { }; break }

Write-Title 'Kontrol listesi 2) Varsayılan oranlarla 500 fatura, haberler bitince mutabakat'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
Restart-Simulator
Restart-InvoiceService

Write-Step 'Önce kalıntıları temizlemek için bir mutabakat çalıştırılıyor'
$flush = Invoke-Reconciliation
Write-Host "  çalışma $($flush.run.id): $($flush.run.status), düzeltilen $($flush.run.fixedCount), raporlanan $($flush.run.reportedCount)"

Write-Step '500 fatura oluşturuluyor (simülatör varsayılan oranlar ve haber sorunlarıyla)'
$numbers = @(New-Invoices 500)
$list = InList $numbers
$statuses = @('Gönderildi', 'İşleme Alındı', 'Onaylandı', 'Reddedildi', 'Başarısız')
$seconds = Wait-InvoicesIn $numbers $statuses 900 'gönderilmiş'
Write-Host "  Hepsi $seconds sn'de gönderildi."
Wait-EventsDone $numbers 600 | Out-Null

Write-Step 'Takılı kalan faturaların 2 dk''dan uzun süredir aynı durumda olması bekleniyor'
$watch = [Diagnostics.Stopwatch]::StartNew()
while ((Count-Service ("SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status IN ('Gönderildi', 'İşleme Alındı') " +
                       "AND updated_at > now() - interval '125 seconds';")) -gt 0 -and $watch.Elapsed.TotalSeconds -lt 180) { Start-Sleep -Seconds 5 }
Write-Host ('  {0:N0} sn beklendi.' -f $watch.Elapsed.TotalSeconds)

Write-DbHeader 'Fatura Servisi' 'Mutabakattan önce: 500 faturanın durum dağılımı'
$distribution = "SELECT status, count(*) FROM invoices WHERE invoice_number IN ($list) GROUP BY status ORDER BY 1;"
Show-ServiceQuery $distribution
$stuckBefore = Count-Service "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status IN ('Gönderildi', 'İşleme Alındı');"
$lostRows = @(Get-ErpRows "SELECT DISTINCT invoice_number FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'LostDecision' ORDER BY 1;")
Write-DbHeader 'ERP Simülatörü' 'Karar haberini hiç göndermediği faturalar (LostDecision)'
Show-ErpQuery "SELECT count(DISTINCT invoice_number) AS karar_haberi_gonderilmeyen FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'LostDecision';"

Write-Step 'Mutabakat çalıştırılıyor'
$run = Invoke-Reconciliation
$id = $run.run.id
Write-Host "  çalışma ${id}: $($run.run.status), kontrol $($run.run.checkedCount), düzeltilen $($run.run.fixedCount), raporlanan $($run.run.reportedCount)"

Write-DbHeader 'Fatura Servisi' 'Mutabakattan sonra'
Show-Run $id
Show-ServiceQuery "SELECT finding_type, action, count(*) FROM reconciliation_findings WHERE run_id = $id GROUP BY 1, 2 ORDER BY 1, 2;"
Show-ServiceQuery $distribution
$stuckAfter = Count-Service "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status IN ('Gönderildi', 'İşleme Alındı');"
$fixedRows = @(Get-ServiceRows ("SELECT DISTINCT invoice_number FROM reconciliation_findings WHERE run_id = $id AND finding_type = 'Takılı Fatura' " +
                                "AND action = 'Düzeltildi' AND invoice_number IN ($list) ORDER BY 1;"))

Check (Write-DbVerdict 'çalışma Tamamlandı' $run.run.status ($run.run.status -eq 'Tamamlandı'))
Check (Write-DbVerdict 'mutabakattan önce takılı kalan = simülatörün karar haberini göndermediği' "$stuckBefore / $($lostRows.Count)" ($stuckBefore -eq $lostRows.Count))
Check (Write-DbVerdict 'mutabakattan sonra Gönderildi ya da İşleme Alındı''da kalan 0' "$stuckAfter" ($stuckAfter -eq 0))
Check (Write-DbVerdict 'düzeltilen fatura sayısı = karar haberi gönderilmeyen fatura sayısı' "$($run.run.fixedCount) / $($lostRows.Count)" `
    ($run.run.fixedCount -eq $lostRows.Count))
Check (Write-DbVerdict 'düzeltilenler tam olarak karar haberi gönderilmeyenler' "$($fixedRows.Count) fatura" (($fixedRows -join ',') -eq ($lostRows -join ',')))

Restart-Simulator
Write-Result $allPassed 'takılı kalan faturalar mutabakatla kesin duruma geçti; düzeltilen sayısı = karar haberi gönderilmeyen sayısı'
