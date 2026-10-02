# Gün 4 - Kontrol listesi 2: bütün hata ve sorun oranları 0 iken 100 fatura. ~1 dk.
#   Hepsi Onaylandı ya da Reddedildi; Reddedildi olanların reject_reason'ı dolu; her haber erp_webhook_events'te tam bir kez.
# "Hata oranları 0" = simülatör POST'ta Success %100; "sorun oranları 0" = Webhooks:Problems'in hepsi 0.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: $_ - simülatör varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Restart-Simulator } catch { }; break }

Write-Title 'Kontrol listesi 2) Bütün hata ve sorun oranları 0, 100 fatura'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
Restart-Simulator (Get-SimSettings)
$numbers = New-Invoices 100
$list = InList $numbers
$seconds = Wait-InvoicesIn $numbers @('Onaylandı', 'Reddedildi') 180 'kesin durumda'
Write-Host "  100 fatura $seconds sn'de kesin durumda"
Wait-EventsDone $numbers | Out-Null

Write-DbHeader 'Fatura Servisi - invoices'
Show-ServiceQuery "SELECT status, count(*) AS fatura, count(reject_reason) AS reject_reason_dolu FROM invoices WHERE invoice_number IN ($list) GROUP BY status ORDER BY status;"
$final = Count-Service "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status IN ('Onaylandı', 'Reddedildi');"
Check (Write-DbVerdict '100 fatura Onaylandı ya da Reddedildi' "$final" ($final -eq 100))
$noReason = Count-Service "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status = 'Reddedildi' AND coalesce(reject_reason, '') = '';"
Check (Write-DbVerdict 'Reddedildi olanların hepsinde reject_reason dolu' "boş olan: $noReason" ($noReason -eq 0))
Show-ServiceQuery "SELECT reject_reason, count(*) FROM invoices WHERE invoice_number IN ($list) AND status = 'Reddedildi' GROUP BY reject_reason ORDER BY 2 DESC;"

Write-DbHeader 'Fatura Servisi - erp_webhook_events' 'Her haber tam bir kez: simülatörün gönderdiği her event_id tabloda bir satır, bir geliş'
Show-ServiceQuery "SELECT event_type, status, count(*) AS satir, count(DISTINCT event_id) AS farkli_event_id, sum(delivery_count) AS gelis FROM erp_webhook_events WHERE invoice_number IN ($list) GROUP BY 1, 2 ORDER BY 1;"
$simIds = @(Get-ErpRows "SELECT DISTINCT event_id FROM webhook_deliveries WHERE invoice_number IN ($list);")
$svc = @(Get-ServiceRows "SELECT count(*) || '|' || count(DISTINCT event_id) || '|' || coalesce(sum(delivery_count), 0) FROM erp_webhook_events WHERE invoice_number IN ($list);")[0] -split '\|'
$missing = Count-Service "SELECT $($simIds.Count) - count(*) FROM erp_webhook_events WHERE event_id IN ($(InList $simIds));"
Check (Write-DbVerdict "simülatörün $($simIds.Count) haberinin hepsi tabloda; 200 satır, 200 farklı event_id, toplam 200 geliş" `
    "simülatör $($simIds.Count) haber, eksik $missing; servis $($svc[0]) satır, $($svc[1]) farklı, $($svc[2]) geliş" `
    ($simIds.Count -eq 200 -and $missing -eq 0 -and $svc[0] -eq '200' -and $svc[1] -eq '200' -and $svc[2] -eq '200'))

Restart-Simulator
Write-Result $allPassed '100 fatura kesin durumda, Reddedildi olanların reject_reason''ı dolu, her haber tabloda tam bir kez'
