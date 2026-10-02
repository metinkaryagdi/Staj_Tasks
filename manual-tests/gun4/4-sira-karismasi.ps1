# Gün 4 - Kontrol listesi 4: sıra karışması %100 iken 20 fatura. ~1 dk.
#   Hepsi Onaylandı ya da Reddedildi kalıyor; sonradan gelen invoice.received haberleri Yok Sayıldı.
# Yalnızca sıra karışması %100; POST Success %100 ve diğer sorunlar 0 (kayıp karar olursa fatura kesin duruma geçemezdi).
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: $_ - simülatör varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Restart-Simulator } catch { }; break }

Write-Title 'Kontrol listesi 4) Sıra karışması %100, 20 fatura'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
Restart-Simulator (Get-SimSettings -Problems @{ OrderMixRate = 100 })
$numbers = New-Invoices 20
$list = InList $numbers
Wait-InvoicesIn $numbers @('Gönderildi', 'İşleme Alındı', 'Onaylandı', 'Reddedildi') 60 'gönderilmiş' | Out-Null
Wait-EventsDone $numbers | Out-Null

Write-DbHeader 'ERP Simülatörü' 'Her faturada karar received''dan önce teslim edildi mi?'
$order = "SELECT d.invoice_number, d.event_type AS karar, to_char(d.completed_at, 'HH24:MI:SS.MS') AS karar_teslim, " +
         "to_char(r.completed_at, 'HH24:MI:SS.MS') AS received_teslim FROM webhook_deliveries d JOIN webhook_deliveries r " +
         "ON r.invoice_id = d.invoice_id AND r.event_type = 'invoice.received' AND r.kind = 'Normal' " +
         "WHERE d.invoice_number IN ($list) AND d.kind = 'Normal' AND d.event_type <> 'invoice.received' ORDER BY 1"
Show-ErpQuery "$order;"
$first = Count-Erp ("SELECT count(*) FROM ($order) x WHERE karar_teslim < received_teslim;")

Write-DbHeader 'Fatura Servisi'
Show-ServiceQuery "SELECT i.invoice_number, i.status AS fatura, e.event_type, e.status AS haber, e.ignore_reason, to_char(e.received_at, 'HH24:MI:SS.MS') AS geldi FROM invoices i JOIN erp_webhook_events e ON e.invoice_number = i.invoice_number WHERE i.invoice_number IN ($list) ORDER BY i.invoice_number, e.received_at;"
$final = Count-Service "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status IN ('Onaylandı', 'Reddedildi');"
$ignored = Count-Service "SELECT count(*) FROM erp_webhook_events WHERE invoice_number IN ($list) AND event_type = 'invoice.received' AND status = 'Yok Sayıldı' AND ignore_reason = 'Geri Götürüyor';"
$decisions = Count-Service "SELECT count(*) FROM erp_webhook_events WHERE invoice_number IN ($list) AND event_type <> 'invoice.received' AND status = 'İşlendi';"

Check (Write-DbVerdict '20 faturada da karar önce teslim edildi' "$first" ($first -eq 20))
Check (Write-DbVerdict '20 karar haberi İşlendi' "$decisions" ($decisions -eq 20))
Check (Write-DbVerdict '20 fatura Onaylandı ya da Reddedildi' "$final" ($final -eq 20))
Check (Write-DbVerdict 'sonradan gelen 20 invoice.received Yok Sayıldı (Geri Götürüyor)' "$ignored" ($ignored -eq 20))

Restart-Simulator
Write-Result $allPassed 'karar önce gelince fatura kesin durumda kalıyor, sonradan gelen invoice.received Yok Sayıldı'
