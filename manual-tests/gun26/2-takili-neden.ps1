# Kontrol listesi 2: Gün 25'teki 14:12 koşusunda eski sürüm kapatıldıktan sonra mutabakatın düzelttiği 1.000 Takılı Fatura neden
# takıldı. Yalnız okuma: o koşunun volume'leri (gun25-gecis-11061412) yalnız iki veritabanı container'ıyla açılır, servisler
# açılmaz (açılsa o verinin üstünde çalışmaya başlarlar). Her Takılı Fatura bulgusu ERP'nin haber teslim kayıtlarıyla
# (webhook_deliveries) ve servise ulaşan haberlerle (erp_webhook_events) eşleştirilir. Çıktı
# manual-tests\output\gun26\a2-takili-neden.txt.
#   .\manual-tests\gun26\2-takili-neden.ps1
. "$PSScriptRoot\_common.ps1"
New-Report 'a2-takili-neden'
Write-Title '1.000 Takılı Fatura: nedenleri'

Push-Location $RepoRoot
try { docker compose down --remove-orphans 2>&1 | Out-Null } finally { Pop-Location }
Use-Gun10Volumes 'gun25-gecis-11061412'
Push-Location $RepoRoot
try { docker compose up -d --wait erp-db invoice-db 2>&1 | Out-Null } finally { Pop-Location }
Write-Line "Volume'ler: staj-tasks_*-db-data-gun25-gecis-11061412 (yalnız erp-db ve invoice-db açık)"

$run = Invoke-InvoiceSql "SELECT run_id FROM reconciliation_findings WHERE finding_type = 'Takılı Fatura' GROUP BY run_id HAVING count(*) = 1000"
Show-Rows 'Mutabakat çalışması:' "SELECT id, status, started_at AT TIME ZONE 'Europe/Istanbul' AS basladi, checked_count, fixed_count, reported_count FROM reconciliation_runs WHERE id = $run"
Show-Rows 'Bu çalışmanın bulguları:' "SELECT finding_type, action, count(*) FROM reconciliation_findings WHERE run_id = $run GROUP BY 1, 2 ORDER BY 1"
Show-Rows 'Takılı Fatura bulguları (beklediği durum, ERP kararı, o durumda kaldığı dakika):' ("SELECT split_part(details, ' durumunda', 1) AS durum, " +
    "substring(details from 'ERP kararı ([a-z]+)') AS erp_karari, count(*), min((regexp_match(details, '(\d+) dk'))[1]::int) AS en_az_dk, " +
    "max((regexp_match(details, '(\d+) dk'))[1]::int) AS en_cok_dk FROM reconciliation_findings WHERE run_id = $run AND finding_type = 'Takılı Fatura' GROUP BY 1, 2 ORDER BY 3 DESC")

$numbers = @((Invoke-InvoiceSql "SELECT invoice_number FROM reconciliation_findings WHERE run_id = $run AND finding_type = 'Takılı Fatura' ORDER BY 1") -split "`r?`n" | Where-Object { $_ -match '^FTR-' })
Write-Line "  Takılı Fatura: $($numbers.Count) fatura"
$list = ($numbers | ForEach-Object { "'$_'" }) -join ','

Write-Line ''
Write-Line '1) ERP: bu faturaların karar haberleri (invoice.approved / invoice.rejected), teslim türüne ve sonucuna göre'
Show-Rows 'webhook_deliveries:' "SELECT event_type, kind, status, count(DISTINCT invoice_number) AS fatura FROM webhook_deliveries WHERE invoice_number IN ($list) AND event_type IN ('invoice.approved', 'invoice.rejected') GROUP BY 1, 2, 3 ORDER BY 4 DESC" -Erp
$lost = [int](Get-SqlScalar "SELECT count(DISTINCT invoice_number) FROM webhook_deliveries WHERE invoice_number IN ($list) AND event_type IN ('invoice.approved', 'invoice.rejected') AND kind = 'LostDecision'")
Check ($lost -eq $numbers.Count) "Kararı simülatörün bilerek kaybettiği (kind = LostDecision, gönderilmedi) fatura: $lost / $($numbers.Count)"
$delivered = [int](Get-SqlScalar "SELECT count(DISTINCT invoice_number) FROM webhook_deliveries WHERE invoice_number IN ($list) AND event_type IN ('invoice.approved', 'invoice.rejected') AND status = 'Delivered'")
Write-Line "  Karar haberi servise teslim edilmiş (Delivered) olan: $delivered"
$noDecision = [int](Get-SqlScalar "SELECT count(*) FROM (SELECT unnest(ARRAY[$list]) AS n) x WHERE NOT EXISTS (SELECT 1 FROM webhook_deliveries d WHERE d.invoice_number = x.n AND d.event_type IN ('invoice.approved', 'invoice.rejected'))")
Write-Line "  Karar haberi hiç planlanmamış olan: $noDecision"

Write-Line ''
Write-Line '2) Servis: bu faturalara ulaşan haberler'
Show-Rows 'erp_webhook_events (fatura sayısı, haber türüne göre):' "SELECT event_type, status, count(DISTINCT invoice_number) AS fatura FROM erp_webhook_events WHERE invoice_number IN ($list) GROUP BY 1, 2 ORDER BY 1, 2"
$decisionArrived = [int](Invoke-InvoiceSql "SELECT count(DISTINCT invoice_number) FROM erp_webhook_events WHERE invoice_number IN ($list) AND event_type IN ('invoice.approved', 'invoice.rejected')")
Check ($decisionArrived -eq 0) "Karar haberi servise ulaşmış olan: $decisionArrived"

Write-Line ''
Write-Line '3) Karşılaştırma: koşunun bütününde kararı kaybolan fatura ve oran'
$allLost = [int](Get-SqlScalar "SELECT count(DISTINCT invoice_number) FROM webhook_deliveries WHERE event_type IN ('invoice.approved', 'invoice.rejected') AND kind = 'LostDecision'")
$allDecided = [int](Get-SqlScalar "SELECT count(DISTINCT invoice_number) FROM webhook_deliveries WHERE event_type IN ('invoice.approved', 'invoice.rejected')")
Write-Line ("  Karar haberi planlanan {0} faturanın {1} tanesinde karar kayboldu (yüzde {2:0.0}); simülatör ayarı LostDecisionRate 5" -f $allDecided, $allLost, (100.0 * $allLost / [Math]::Max(1, $allDecided)))
Push-Location $RepoRoot
try {
    $lostNumbers = @((docker compose exec -T erp-db psql -U erp -d erp_simulator -tAc "SELECT DISTINCT invoice_number FROM webhook_deliveries WHERE event_type IN ('invoice.approved', 'invoice.rejected') AND kind = 'LostDecision'") | Where-Object { $_ -match '^FTR-' })
}
finally { Pop-Location }
$others = @($lostNumbers | Where-Object { $numbers -notcontains $_ })
Write-Line "  Kararı kaybolup bu çalışmada Takılı Fatura olarak düzeltilmeyen: $($others.Count)"
if ($others.Count -gt 0) {
    $otherList = ($others | ForEach-Object { "'$_'" }) -join ','
    Show-Rows '  Bunların servisteki durumu ve iptal satırı:' ("SELECT i.status, (o.invoice_number IS NOT NULL) AS iptal_istendi, count(*) FROM invoices i LEFT JOIN erp_outbox o ON o.invoice_number = i.invoice_number AND o.kind = 'İptal' " +
        "WHERE i.invoice_number IN ($otherList) GROUP BY 1, 2 ORDER BY 3 DESC")
    Show-Rows '  Bunlar için başka çalışmalardaki bulgular:' "SELECT run_id, finding_type, action, count(*) FROM reconciliation_findings WHERE invoice_number IN ($otherList) GROUP BY 1, 2, 3 ORDER BY 1"
}

Push-Location $RepoRoot
try { docker compose down 2>&1 | Out-Null } finally { Pop-Location }
Write-Line ''
Write-Line 'Veritabanı container''ları kapatıldı; volume''ler duruyor.'
Save-Report
