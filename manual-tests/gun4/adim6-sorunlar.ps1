# Gün 4 - Adım 6: simülatörün haberlerde bilerek çıkardığı sorunlar; her biri tek başına %100. ~5 dk.
# Fatura gönderimi her bölümde sorunsuz (Success %100); yalnızca o bölümün haber sorunu %100, diğerleri 0.
#
#   A) Çift gönderim: her haber aynı event_id ile iki kez -> serviste her haber tek satır, delivery_count 2; faturalar kesin durumda.
#   B) Sıra karışması: karar received'dan önce -> faturalar kesin durumda, sonradan gelen received'lar Yok Sayıldı (Geri Götürüyor).
#   C) Kayıp karar: karar hiç gönderilmez -> faturalar İşleme Alındı'da kalır; simülatörde karar satırı Skipped.
#   D) Sahte haber: yanlış imzalı karar -> 401, simülatörde Rejected, 1 kez gönderildi; serviste kaydı yok; logda bad-signature.
#   E) Eski haber: bir haber 10 dk önceki damgayla (geçerli imza) yeniden -> 401, Rejected, 1 kez; logda expired;
#      serviste o haber yalnızca ilk gelişinden (delivery_count 1).
#
# Sonunda simülatör varsayılan ayarlarına döner.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: $_ - simülatör varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Restart-Simulator } catch { }; break }

Write-Title 'Adım 6) Simülatörün haber sorunları (her biri tek başına %100)'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }
function InList([string[]]$Numbers) { ($Numbers | ForEach-Object { "'$_'" }) -join ',' }

function Settings([string]$Problem) {
    $s = @{ Simulator__Rates__Success = 100; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0
            Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0
            Webhooks__Problems__DuplicateRate = 0; Webhooks__Problems__OrderMixRate = 0; Webhooks__Problems__LostDecisionRate = 0
            Webhooks__Problems__FakeRate = 0; Webhooks__Problems__ReplayRate = 0 }
    $s["Webhooks__Problems__$Problem"] = 100
    $s
}

# Önce faturaların hepsi simülatöre ulaşıp haberleri planlanana kadar (servis gönderimi 202'den sonra arka planda yapar),
# sonra simülatörde bu faturaların gönderilecek haberi kalmayana kadar (Pending yok) bekler.
function Wait-DeliveriesDone([string[]]$Numbers, [int]$TimeoutSeconds = 120) {
    $list = InList $Numbers
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ([int]@(Get-ErpRows "SELECT count(DISTINCT invoice_number) FROM webhook_deliveries WHERE invoice_number IN ($list);")[0] -lt $Numbers.Count) {
        if ($watch.Elapsed.TotalSeconds -gt 30) { throw 'Faturalar 30 sn içinde simülatöre ulaşmadı.' }
        Start-Sleep -Milliseconds 300
    }
    while ([int]@(Get-ErpRows "SELECT count(*) FROM webhook_deliveries WHERE invoice_number IN ($list) AND status = 'Pending';")[0] -gt 0) {
        if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw "Haberler $TimeoutSeconds sn içinde bitmedi." }
        Start-Sleep -Seconds 1
    }
    Start-Sleep -Milliseconds 500
    [math]::Round($watch.Elapsed.TotalSeconds, 1)
}

function Run-Section([string]$Title, [string]$Problem) {
    Write-Step $Title
    Restart-Simulator (Settings $Problem)
    $script:sectionStart = [datetime]::UtcNow.AddSeconds(-1)
    $numbers = @()
    for ($i = 0; $i -lt 5; $i++) { $numbers += (New-ServiceInvoice).InvoiceNumber }
    Write-Host "  $($numbers[0]) .. $($numbers[-1]) oluşturuldu; haberlerin bitmesi bekleniyor..."
    $seconds = Wait-DeliveriesDone $numbers
    Write-Host "  $seconds sn'de bitti"
    $list = InList $numbers
    Show-ErpQuery "SELECT invoice_number, event_type, kind, status, attempt_count, last_http_status FROM webhook_deliveries WHERE invoice_number IN ($list) ORDER BY invoice_number, due_at;"
    Show-ServiceQuery "SELECT i.invoice_number, i.status, e.event_type, e.status AS haber, e.ignore_reason, e.delivery_count FROM invoices i LEFT JOIN erp_webhook_events e ON e.invoice_number = i.invoice_number WHERE i.invoice_number IN ($list) ORDER BY i.invoice_number, e.received_at;"
    $list
}

function Count-Service([string]$Sql) { [int]@(Get-ServiceRows $Sql)[0] }
function Count-Erp([string]$Sql) { [int]@(Get-ErpRows $Sql)[0] }

Wait-Service

# --- A) ----------------------------------------------------------------------------------------------------------------
$list = Run-Section 'A) Çift gönderim %100' 'DuplicateRate'
Write-DbHeader 'A) Çift gönderim'
$final = Count-Service "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status IN ('Onaylandı', 'Reddedildi');"
$ev = @(Get-ServiceRows "SELECT count(*) || '|' || count(*) FILTER (WHERE delivery_count = 2) FROM erp_webhook_events WHERE invoice_number IN ($list);")[0] -split '\|'
$dup = Count-Erp "SELECT count(*) FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'Duplicate' AND status = 'Delivered';"
Check (Write-DbVerdict 'simülatör 10 haberin 10''unu ikinci kez gönderdi' "Duplicate Delivered: $dup" ($dup -eq 10))
Check (Write-DbVerdict 'serviste 10 satır, hepsi delivery_count 2 (tekrar işlenmedi)' "$($ev[0]) satır, $($ev[1]) tanesi delivery_count 2" ($ev[0] -eq '10' -and $ev[1] -eq '10'))
Check (Write-DbVerdict '5 fatura Onaylandı/Reddedildi' "$final" ($final -eq 5))

# --- B) ----------------------------------------------------------------------------------------------------------------
$list = Run-Section 'B) Sıra karışması %100' 'OrderMixRate'
Write-DbHeader 'B) Sıra karışması'
$final = Count-Service "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status IN ('Onaylandı', 'Reddedildi');"
$first = Count-Erp "SELECT count(*) FROM webhook_deliveries d JOIN webhook_deliveries r ON r.invoice_id = d.invoice_id AND r.event_type = 'invoice.received' WHERE d.invoice_number IN ($list) AND d.event_type <> 'invoice.received' AND d.completed_at < r.completed_at;"
$ignored = Count-Service "SELECT count(*) FROM erp_webhook_events WHERE invoice_number IN ($list) AND event_type = 'invoice.received' AND status = 'Yok Sayıldı' AND ignore_reason = 'Geri Götürüyor';"
Check (Write-DbVerdict 'simülatör 5 faturada da kararı önce teslim etti' "$first" ($first -eq 5))
Check (Write-DbVerdict '5 fatura Onaylandı/Reddedildi' "$final" ($final -eq 5))
Check (Write-DbVerdict '5 invoice.received Yok Sayıldı (Geri Götürüyor)' "$ignored" ($ignored -eq 5))

# --- C) ----------------------------------------------------------------------------------------------------------------
$list = Run-Section 'C) Kayıp karar %100' 'LostDecisionRate'
Write-DbHeader 'C) Kayıp karar'
$processing = Count-Service "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status = 'İşleme Alındı';"
$skipped = Count-Erp "SELECT count(*) FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'LostDecision' AND status = 'Skipped' AND attempt_count = 0;"
$decisions = Count-Service "SELECT count(*) FROM erp_webhook_events WHERE invoice_number IN ($list) AND event_type <> 'invoice.received';"
Check (Write-DbVerdict 'simülatörde 5 karar Skipped, hiç gönderilmedi' "$skipped" ($skipped -eq 5))
Check (Write-DbVerdict 'serviste karar haberi yok; 5 fatura İşleme Alındı''da' "karar haberi $decisions, İşleme Alındı $processing" ($decisions -eq 0 -and $processing -eq 5))

# --- D) ----------------------------------------------------------------------------------------------------------------
$list = Run-Section 'D) Sahte haber %100' 'FakeRate'
Write-DbHeader 'D) Sahte haber'
$fake = @(Get-ErpRows "SELECT count(*) || '|' || count(*) FILTER (WHERE status = 'Rejected' AND last_http_status = 401 AND attempt_count = 1) FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'Fake';")[0] -split '\|'
$fakeIds = @(Get-ErpRows "SELECT event_id FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'Fake';")
$stored = Count-Service "SELECT count(*) FROM erp_webhook_events WHERE event_id IN ($(InList $fakeIds));"
$final = Count-Service "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status IN ('Onaylandı', 'Reddedildi');"
$logged = @(Get-WebhookLog $sectionStart | Where-Object { $_ -match 'http=401 reason=bad-signature' }).Count
Check (Write-DbVerdict '5 sahte haber 401 aldı, Rejected, tekrar gönderilmedi (1 deneme)' "$($fake[0]) sahte, $($fake[1]) tanesi 401/Rejected/1 deneme" ($fake[0] -eq '5' -and $fake[1] -eq '5'))
Check (Write-DbVerdict 'serviste sahte haber kaydı yok; logda bad-signature' "kayıt $stored, log $logged" ($stored -eq 0 -and $logged -ge 5))
Check (Write-DbVerdict '5 fatura kendi gerçek kararıyla kesin durumda' "$final" ($final -eq 5))

# --- E) ----------------------------------------------------------------------------------------------------------------
$list = Run-Section 'E) Eski haber %100' 'ReplayRate'
Write-DbHeader 'E) Eski haber'
$replay = @(Get-ErpRows "SELECT count(*) || '|' || count(*) FILTER (WHERE status = 'Rejected' AND last_http_status = 401 AND attempt_count = 1) FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'Replay';")[0] -split '\|'
$replayIds = @(Get-ErpRows "SELECT event_id FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'Replay';")
$counts = @(Get-ServiceRows "SELECT count(*) || '|' || coalesce(max(delivery_count), 0) FROM erp_webhook_events WHERE event_id IN ($(InList $replayIds));")[0] -split '\|'
$logged = @(Get-WebhookLog $sectionStart | Where-Object { $_ -match 'http=401 reason=expired' }).Count
$final = Count-Service "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status IN ('Onaylandı', 'Reddedildi');"
Check (Write-DbVerdict '5 eski haber 401 aldı, Rejected, tekrar gönderilmedi (1 deneme)' "$($replay[0]) eski, $($replay[1]) tanesi 401/Rejected/1 deneme" ($replay[0] -eq '5' -and $replay[1] -eq '5'))
Check (Write-DbVerdict 'asıl haberler serviste 1 kez (eski gönderim sayılmadı); logda expired' "$($counts[0]) satır, en çok delivery_count $($counts[1]), log $logged" ($counts[0] -eq '5' -and $counts[1] -eq '1' -and $logged -ge 5))
Check (Write-DbVerdict '5 fatura kesin durumda' "$final" ($final -eq 5))

Restart-Simulator
Write-Result $allPassed 'çift gönderim tekrar işlenmiyor; sıra karışmasında karar kalıyor, received Yok Sayıldı; kayıp kararda fatura İşleme Alındı''da kalıyor; sahte ve eski haber 401 alıp tekrar gönderilmiyor'
