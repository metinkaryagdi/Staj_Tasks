# Gün 7 - Adım 3: ERP'nin karar vermediği takılı fatura "ERP Karar Vermedi" olarak raporlanıyor; karar gelince sonraki
# çalışma faturayı düzeltiyor. ~7 dk.
#
#   Simülatör: karar, invoice.received'dan 240 sn sonra verilir ve karar haberi servise hiç gönderilmez (LostDecisionRate
#   100): faturayı yalnızca mutabakat düzeltebilir. Servis: takılı 1 dk, karar yok eşiği 2 dk (ayar dosyasında 2 / 30).
#   1) Fatura İşleme Alındı'da 2 dk'dan uzun kalınca iki çalışma: ikisi de "ERP Karar Vermedi" yazar; fatura detayında
#      yalnızca en sonuncusu görünür.
#   2) ERP karar verdikten sonraki çalışma: fatura ERP'nin kararına geçer ("Takılı Fatura", Düzeltildi).
#
# Önce servisin yeni kodla derlenmiş olması gerekir: docker compose build invoice-service
# Sonda simülatör ve servis ayar dosyasındaki değerlerle yeniden başlatılır.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: $_ - simülatör ve servis varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Restart-Simulator; Restart-InvoiceService } catch { }; break }

Write-Title 'Adım 3) ERP Karar Vermedi bulgusu ve karar gelince düzeltme'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
$sim = Get-SimSettings 'Success' @{ LostDecisionRate = 100 }
$sim['Webhooks__FirstEventMinSeconds'] = 2; $sim['Webhooks__FirstEventMaxSeconds'] = 4
$sim['Webhooks__SecondEventMinSeconds'] = 240; $sim['Webhooks__SecondEventMaxSeconds'] = 240
Restart-Simulator $sim
Restart-InvoiceService @{ Reconciliation__StuckAfterMinutes = 1; Reconciliation__NoDecisionAfterMinutes = 2 }

$number = @(New-Invoices 1)[0]
Wait-InvoicesIn @($number) @('İşleme Alındı') 60 'İşleme Alındı' | Out-Null
$decisionAt = @(Get-ErpRows "SELECT to_char(occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') FROM webhook_deliveries WHERE invoice_number = '$number' AND event_type <> 'invoice.received' AND kind = 'LostDecision';")[0]
Show-ErpQuery "SELECT invoice_number, event_type, kind, status, occurred_at FROM webhook_deliveries WHERE invoice_number = '$number' ORDER BY occurred_at;"
Write-Host "  ERP'nin kararı (UTC): $decisionAt; karar haberi gönderilmeyecek (Skipped)."

# --- 1) Karar yokken -------------------------------------------------------------------------------------------------
Write-Step "Fatura İşleme Alındı'da 2 dk'dan uzun kalana kadar bekleniyor"
while ((Count-Service "SELECT count(*) FROM invoices WHERE invoice_number = '$number' AND updated_at < now() - interval '2 minutes 5 seconds';") -eq 0) {
    Start-Sleep -Seconds 5
}
$first = Invoke-Reconciliation
$second = Invoke-Reconciliation
$runs = "$($first.run.id), $($second.run.id)"

Write-DbHeader 'Fatura Servisi' "1) Çalışma $runs, ERP'nin kararı yokken"
Show-ServiceQuery "SELECT run_id, finding_type, action, details FROM reconciliation_findings WHERE invoice_number = '$number' ORDER BY id;"
Show-ServiceQuery "SELECT invoice_number, status, updated_at FROM invoices WHERE invoice_number = '$number';"
$rows = @(Get-ServiceRows "SELECT run_id, action FROM reconciliation_findings WHERE invoice_number = '$number' AND finding_type = 'ERP Karar Vermedi' ORDER BY id;")
Check (Write-DbVerdict "iki çalışmada da 'ERP Karar Vermedi', Raporlandı ($runs)" "$($rows -join ' / ')" `
    ($rows.Count -eq 2 -and $rows[0] -eq "$($first.run.id)|Raporlandı" -and $rows[1] -eq "$($second.run.id)|Raporlandı"))
$status = @(Get-ServiceRows "SELECT status FROM invoices WHERE invoice_number = '$number';")[0]
Check (Write-DbVerdict 'fatura değişmedi: İşleme Alındı' $status ($status -eq 'İşleme Alındı'))

$details = (Get-Api "/api/v1/invoices/$number/details").Json
$shown = @($details.findings | Where-Object { $_.findingType -eq 'ERP Karar Vermedi' })
Check (Write-DbVerdict "fatura detayında tek 'ERP Karar Vermedi', en sonuncusu (çalışma $($second.run.id))" `
    "$($shown.Count) tane, çalışma $($shown.runId -join ', ')" ($shown.Count -eq 1 -and $shown[0].runId -eq $second.run.id))
$inRun = @((Get-RunDetail $second.run.id).findings | Where-Object { $_.invoiceNumber -eq $number -and $_.findingType -eq 'ERP Karar Vermedi' })
Check (Write-DbVerdict "mutabakat çalışması $($second.run.id) bulgularında var" "$($inRun.Count) tane" ($inRun.Count -eq 1))

# --- 2) Karar geldikten sonra ----------------------------------------------------------------------------------------
Write-Step "ERP'nin karar zamanı ($decisionAt UTC) bekleniyor"
while ([DateTime]::UtcNow -lt [DateTime]::ParseExact($decisionAt, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture).AddSeconds(3)) {
    Start-Sleep -Seconds 5
}
$erpDecision = @(Get-ErpRows "SELECT event_type FROM webhook_deliveries WHERE invoice_number = '$number' AND kind = 'LostDecision';")[0]
$expected = if ($erpDecision -eq 'invoice.approved') { 'Onaylandı' } else { 'Reddedildi' }
$third = Invoke-Reconciliation

Write-DbHeader 'Fatura Servisi' "2) Çalışma $($third.run.id), ERP karar verdikten sonra ($erpDecision)"
Show-ServiceQuery "SELECT run_id, finding_type, action, details FROM reconciliation_findings WHERE invoice_number = '$number' ORDER BY id;"
Show-ServiceQuery "SELECT invoice_number, status, reject_reason, updated_at FROM invoices WHERE invoice_number = '$number';"
$fix = @(Get-ServiceRows "SELECT finding_type, action FROM reconciliation_findings WHERE invoice_number = '$number' AND run_id = $($third.run.id);")
$status = @(Get-ServiceRows "SELECT status FROM invoices WHERE invoice_number = '$number';")[0]
Check (Write-DbVerdict "çalışma $($third.run.id): Takılı Fatura, Düzeltildi; fatura $expected" "$($fix -join ' / '); fatura $status" `
    ($fix.Count -eq 1 -and $fix[0] -eq 'Takılı Fatura|Düzeltildi' -and $status -eq $expected))

Write-Host ''
Write-Host "Ekranda: http://localhost:5100/faturalar/$number (Mutabakat bulguları) ve /mutabakat?calisma=$($second.run.id) (Raporlanan bulgular)."

Restart-Simulator
Restart-InvoiceService
Write-Result $allPassed 'Adım 3'
