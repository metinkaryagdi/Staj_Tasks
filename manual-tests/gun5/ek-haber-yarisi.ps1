# Gün 5 - Ek (kontrol listesinde yok, işin 6. maddesi): mutabakat bir faturayı değiştirirken aynı faturaya bir haber gelirse
# ikisi birbirini bozmaz. ~3 dk.
#
# Simülatör karar haberini hiç göndermez (LostDecisionRate %100), fatura 1 dk'dan uzun süre İşleme Alındı'da kalır.
# Faturanın satırı 8 sn boyunca başka bir oturumda kilitlenir (SELECT ... FOR UPDATE). Bu sürede mutabakat başlatılır (düzeltme
# kilidi bekler) ve "kaybolan" karar haberi geçerli imzayla servise gönderilir (haber de kilidi bekler, 503 alırsa yeniden dener).
# Kilit açılınca ikisinden biri önce işler; sonuç hangi sırayla olursa olsun fatura bir kez, doğru karara ilerlemiş olmalı:
#   a) mutabakat önce: fatura karar durumunda, bulgu Düzeltildi, haber Yok Sayıldı (Kesin Durumda)
#   b) haber önce:     fatura karar durumunda, haber İşlendi, mutabakat faturaya dokunmaz (bulgu yok)
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: ayarlar varsayılana döndürülüyor." -ForegroundColor Red
       try { Restart-Simulator; Restart-InvoiceService } catch { }; break }

Write-Title 'Ek) Mutabakat fatura satırını değiştirirken aynı faturanın haberi geliyor: ikisi birbirini bozmuyor'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
Restart-Simulator (Get-SimSettings -Problems @{ LostDecisionRate = 100 })
Restart-InvoiceService @{ Reconciliation__StuckAfterMinutes = 1 }

$number = @(New-Invoices 1)[0]
Wait-InvoicesIn @($number) @('Gönderildi', 'İşleme Alındı') 60 'gönderilmiş' | Out-Null
Wait-EventsDone @($number) | Out-Null
Write-Step 'Faturanın 1 dk''dan uzun süredir aynı durumda kalması ve karar zamanının gelmesi bekleniyor'
$watch = [Diagnostics.Stopwatch]::StartNew()
while ((Count-Service "SELECT count(*) FROM invoices WHERE invoice_number = '$number' AND updated_at > now() - interval '70 seconds';") -gt 0 -and $watch.Elapsed.TotalSeconds -lt 150) {
    Start-Sleep -Seconds 5
}
Write-Host ('  {0:N0} sn beklendi.' -f $watch.Elapsed.TotalSeconds)

$lost = @(Get-ErpRows "SELECT event_id, event_type, payload FROM webhook_deliveries WHERE invoice_number = '$number' AND kind = 'LostDecision';")[0] -split '\|', 3
$expected = if ($lost[1] -eq 'invoice.approved') { 'Onaylandı' } else { 'Reddedildi' }
Write-DbHeader 'ERP Simülatörü' 'Gönderilmeyen karar haberi'
Show-ErpQuery "SELECT event_id, event_type, kind, status FROM webhook_deliveries WHERE invoice_number = '$number' ORDER BY id;"
Write-DbHeader 'Fatura Servisi' 'Başlangıç: fatura takılı'
Show-ServiceQuery "SELECT invoice_number, status, erp_reference, updated_at FROM invoices WHERE invoice_number = '$number';"

Write-Step 'Faturanın satırı 8 sn boyunca başka bir oturumda kilitleniyor'
$lockSql = "BEGIN; SELECT 1 FROM invoices WHERE invoice_number = '$number' FOR UPDATE; SELECT pg_sleep(8); COMMIT;"
$job = Start-Job -ScriptBlock {
    param($root, $sql)
    Set-Location $root
    & docker compose exec -T invoice-db psql -U invoice -d invoice_service -c $sql
} -ArgumentList $RepoRoot, $lockSql
Start-Sleep -Seconds 2

Write-Step 'Kilit tutulurken mutabakat başlatılıyor ve kaybolan karar haberi geçerli imzayla gönderiliyor'
$started = Start-Reconciliation
Write-Host "  mutabakat: HTTP $($started.Status), çalışma $($started.RunId)"
$secret = Get-WebhookSecret
$body = [Text.Encoding]::UTF8.GetBytes($lost[2])
$codes = @()
for ($i = 0; $i -lt 40; $i++) {
    $timestamp = "$(Get-UnixNow)"
    $r = Send-Webhook $body $timestamp (Get-WebhookSignature $secret $timestamp $body)
    $codes += $r.Status
    if ($r.Status -eq 200) { break }
    Start-Sleep -Milliseconds 500
}
Write-Host "  haber cevapları: $($codes -join ', ')"
Wait-Job $job | Out-Null
Remove-Job $job
$run = Wait-RunDone $started.RunId 60
Write-Host "  çalışma $($run.run.id): $($run.run.status), düzeltilen $($run.run.fixedCount)"

Write-DbHeader 'Fatura Servisi' 'Sonuç: fatura, haber ve bulgu'
Show-ServiceQuery "SELECT invoice_number, status, reject_reason, erp_reference FROM invoices WHERE invoice_number = '$number';"
Show-ServiceQuery "SELECT event_id, event_type, status, ignore_reason, delivery_count FROM erp_webhook_events WHERE invoice_number = '$number' ORDER BY received_at;"
Show-Findings $started.RunId "AND invoice_number = '$number'"
$invoice = @(Get-ServiceRows "SELECT status FROM invoices WHERE invoice_number = '$number';")[0]
$events = @(Get-ServiceRows "SELECT event_type, status, coalesce(ignore_reason, '') FROM erp_webhook_events WHERE invoice_number = '$number' AND event_id = '$($lost[0])';")
$findings = Count-Service "SELECT count(*) FROM reconciliation_findings WHERE run_id = $($started.RunId) AND invoice_number = '$number' AND action = 'Düzeltildi';"
$waiting = Count-Service "SELECT count(*) FROM erp_webhook_events WHERE invoice_number = '$number' AND status = 'Bekliyor';"
$reconciliationFirst = ($findings -eq 1 -and $events[0] -eq "$($lost[1])|Yok Sayıldı|Kesin Durumda")
$eventFirst = ($findings -eq 0 -and $events[0] -eq "$($lost[1])|İşlendi|")
$order = if ($reconciliationFirst) { 'mutabakat önce' } elseif ($eventFirst) { 'haber önce' } else { 'tutarsız' }

Check (Write-DbVerdict 'çalışma Tamamlandı, haber sonunda 200 aldı' "$($run.run.status), $($codes[-1])" ($run.run.status -eq 'Tamamlandı' -and $codes[-1] -eq 200))
Check (Write-DbVerdict "fatura tek karara ilerledi: $expected" $invoice ($invoice -eq $expected))
Check (Write-DbVerdict 'ikisinden biri uyguladı, diğeri dokunmadı (mutabakat önce ya da haber önce)' $order ($reconciliationFirst -or $eventFirst))
Check (Write-DbVerdict 'Bekliyor haber kalmadı' "$waiting" ($waiting -eq 0))

Restart-Simulator
Restart-InvoiceService
Write-Result $allPassed "satır kilidi altında mutabakat ve haber birbirini bozmadı ($order)"
