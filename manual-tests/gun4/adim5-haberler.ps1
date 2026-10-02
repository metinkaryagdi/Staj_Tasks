# Gün 4 - Adım 5: simülatör haberleri kendisi gönderiyor (imzalı, zamanlı, tekrar denemeli). ~3 dk.
# Henüz sorun çıkarmıyor (Adım 6); bu yüzden A bölümü kontrol listesi 2'nin ön provasıdır.
#
#   A) Simülatör Success %100, 100 fatura: hepsi Onaylandı ya da Reddedildi; Reddedildi olanların reject_reason'ı dolu;
#      her haber erp_webhook_events'te tam bir kez (200 satır, delivery_count 1); simülatörde 200 gönderim, hepsi ilk
#      denemede Delivered; zamanlar görevdeki aralıklarda (received kayıttan 2-10 sn, karar received'dan 2-20 sn sonra);
#      onay oranı ~%80.
#   B) Tekrar gönderim: 5 fatura Gönderildi olunca Fatura Servisi 30 sn durdurulur. Bu sırada zamanı gelen haberler
#      ulaşamaz; simülatör 5, 10, 20 ... sn arayla tekrar dener. Servis açılınca hepsi ulaşır, 5 fatura kesin duruma geçer.
#
# Sonunda simülatör varsayılan ayarlarına döner; servis açık bırakılır.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: $_ - servis başlatılıyor, simülatör varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Invoke-Compose @('start', 'invoice-service') } catch { }; try { Restart-Simulator } catch { }; break }

Write-Title 'Adım 5) Simülatörün gönderdiği haberler: 100 fatura (hata yok) ve servis kapalıyken tekrar gönderim'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

$success = @{ Simulator__Rates__Success = 100; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0
              Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0 }

function InList([string[]]$Numbers) { ($Numbers | ForEach-Object { "'$_'" }) -join ',' }

# Verilen faturaların hepsi Onaylandı ya da Reddedildi olana kadar bekler; geçen saniyeyi döner.
function Wait-AllFinal([string[]]$Numbers, [int]$TimeoutSeconds = 180) {
    $list = InList $Numbers
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $last = -1
    while ($true) {
        $open = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status NOT IN ('Onaylandı', 'Reddedildi');")[0]
        if ($open -eq 0) { return [math]::Round($watch.Elapsed.TotalSeconds, 1) }
        if ($open -ne $last) { Write-Host ('  {0,5:N0} sn: {1} fatura henüz kesin durumda değil' -f $watch.Elapsed.TotalSeconds, $open) -ForegroundColor DarkGray }
        $last = $open
        if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw "$TimeoutSeconds sn içinde $open fatura kesin duruma geçmedi." }
        Start-Sleep -Milliseconds 1000
    }
}

Wait-Service
Restart-Simulator $success

# --- A) ----------------------------------------------------------------------------------------------------------------
Write-Step 'A) 100 fatura, simülatör Success %100'
$numbers = @()
for ($i = 0; $i -lt 100; $i++) { $numbers += (New-ServiceInvoice).InvoiceNumber }
Write-Host "  $($numbers[0]) .. $($numbers[-1]) oluşturuldu"
$seconds = Wait-AllFinal $numbers
Write-Host "  hepsi $seconds sn'de kesin durumda"
$list = InList $numbers

Write-DbHeader 'A) Fatura Servisi'
Show-ServiceQuery "SELECT status, count(*), count(reject_reason) AS reject_reason_dolu FROM invoices WHERE invoice_number IN ($list) GROUP BY status ORDER BY status;"
$byStatus = @{}
Get-ServiceRows "SELECT status, count(*) FROM invoices WHERE invoice_number IN ($list) GROUP BY status;" | ForEach-Object { $p = $_ -split '\|'; $byStatus[$p[0]] = [int]$p[1] }
$approved = [int]$byStatus['Onaylandı']; $rejected = [int]$byStatus['Reddedildi']
Check (Write-DbVerdict '100 fatura Onaylandı ya da Reddedildi' "Onaylandı $approved + Reddedildi $rejected = $($approved + $rejected)" ($approved + $rejected -eq 100))
$noReason = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status = 'Reddedildi' AND (reject_reason IS NULL OR reject_reason = '');")[0]
Check (Write-DbVerdict 'Reddedildi olanların hepsinde reject_reason dolu' "reject_reason boş: $noReason" ($noReason -eq 0))
$withReason = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status <> 'Reddedildi' AND reject_reason IS NOT NULL;")[0]
Check (Write-DbVerdict 'Onaylandı olanlarda reject_reason boş' "dolu olan: $withReason" ($withReason -eq 0))

Show-ServiceQuery "SELECT event_type, status, count(*), sum(delivery_count) AS gelis FROM erp_webhook_events WHERE invoice_number IN ($list) GROUP BY event_type, status ORDER BY event_type;"
$ev = @(Get-ServiceRows "SELECT count(*) || '|' || count(DISTINCT event_id) || '|' || coalesce(max(delivery_count), 0) || '|' || count(*) FILTER (WHERE status = 'İşlendi') FROM erp_webhook_events WHERE invoice_number IN ($list);")[0] -split '\|'
Check (Write-DbVerdict '200 haber, 200 farklı event_id, hepsi delivery_count 1 ve İşlendi' "$($ev[0]) satır, $($ev[1]) farklı, en çok $($ev[2]) geliş, $($ev[3]) İşlendi" `
    ($ev[0] -eq '200' -and $ev[1] -eq '200' -and $ev[2] -eq '1' -and $ev[3] -eq '200'))

Write-DbHeader 'A) ERP Simülatörü (webhook_deliveries)'
Show-ErpQuery "SELECT event_type, status, attempt_count, count(*) FROM webhook_deliveries WHERE invoice_number IN ($list) GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;"
$sim = @(Get-ErpRows "SELECT count(*) || '|' || count(*) FILTER (WHERE status = 'Delivered' AND attempt_count = 1) FROM webhook_deliveries WHERE invoice_number IN ($list);")[0] -split '\|'
Check (Write-DbVerdict '200 gönderim, hepsi ilk denemede Delivered' "$($sim[0]) gönderim, $($sim[1]) ilk denemede" ($sim[0] -eq '200' -and $sim[1] -eq '200'))
$timing = "SELECT round(min(EXTRACT(EPOCH FROM r.due_at - i.received_at))::numeric, 2), round(max(EXTRACT(EPOCH FROM r.due_at - i.received_at))::numeric, 2), " +
          "round(min(EXTRACT(EPOCH FROM d.due_at - r.due_at))::numeric, 2), round(max(EXTRACT(EPOCH FROM d.due_at - r.due_at))::numeric, 2) " +
          "FROM invoices i JOIN webhook_deliveries r ON r.invoice_id = i.id AND r.event_type = 'invoice.received' " +
          "JOIN webhook_deliveries d ON d.invoice_id = i.id AND d.event_type <> 'invoice.received' WHERE i.invoice_number IN ($list)"
$t = @(Get-ErpRows "$timing;")[0] -split '\|'
$inv = [Globalization.CultureInfo]::InvariantCulture
Check (Write-DbVerdict 'received kayıttan 2-10 sn, karar received''dan 2-20 sn sonra (planlanan)' "received $($t[0])-$($t[1]) sn, karar $($t[2])-$($t[3]) sn" `
    ([double]::Parse($t[0], $inv) -ge 2 -and [double]::Parse($t[1], $inv) -le 10 -and [double]::Parse($t[2], $inv) -ge 2 -and [double]::Parse($t[3], $inv) -le 20))
$late = "SELECT round(max(EXTRACT(EPOCH FROM e.received_at - e.occurred_at))::numeric, 3) FROM erp_webhook_events e WHERE e.invoice_number IN ($list);"
Write-Host "  Haberin planlanan zamanı ile servise ulaşması arasındaki en büyük fark: $(@(Get-ServiceRows $late)[0]) sn" -ForegroundColor DarkGray
Write-Host "  Onay oranı: $approved / 100 (görev %80; 100 faturada rastgele sapma normal)" -ForegroundColor DarkGray

# --- B) ----------------------------------------------------------------------------------------------------------------
Write-Step 'B) 5 fatura Gönderildi olunca Fatura Servisi 30 sn durduruluyor'
$five = @()
for ($i = 0; $i -lt 5; $i++) { $five += (New-ServiceInvoice).InvoiceNumber }
$fiveList = InList $five
$watch = [Diagnostics.Stopwatch]::StartNew()
while ([int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE invoice_number IN ($fiveList) AND status = 'Gönderildi';")[0] -lt 5) {
    if ($watch.Elapsed.TotalSeconds -gt 30) { throw '5 fatura 30 sn içinde Gönderildi olmadı.' }
    Start-Sleep -Milliseconds 100
}
Invoke-Compose @('stop', 'invoice-service')
$stoppedAt = [datetime]::UtcNow
Write-Host "  servis durduruldu ($($stoppedAt.ToString('HH:mm:ss')) UTC); 30 sn bekleniyor..."
Start-Sleep -Seconds 30
Invoke-Compose @('start', 'invoice-service')
Wait-Service
Write-Host "  servis açıldı ($([datetime]::UtcNow.ToString('HH:mm:ss')) UTC)"
$seconds = Wait-AllFinal $five
Write-Host "  5 fatura açıldıktan $seconds sn sonra kesin durumda"

Write-DbHeader 'B) ERP Simülatörü (webhook_deliveries)'
Show-ErpQuery "SELECT invoice_number, event_type, status, attempt_count, last_http_status, to_char(due_at, 'HH24:MI:SS') AS son_plan FROM webhook_deliveries WHERE invoice_number IN ($fiveList) ORDER BY invoice_number, id;"
$retried = [int]@(Get-ErpRows "SELECT count(*) FROM webhook_deliveries WHERE invoice_number IN ($fiveList) AND attempt_count > 1;")[0]
$delivered = [int]@(Get-ErpRows "SELECT count(*) FROM webhook_deliveries WHERE invoice_number IN ($fiveList) AND status = 'Delivered';")[0]
Check (Write-DbVerdict 'en az bir haber tekrar denendi; 10 haberin hepsi sonunda Delivered' "tekrar denenen $retried, Delivered $delivered" ($retried -ge 1 -and $delivered -eq 10))

Write-Host ''
Write-Host '  Simülatör logu (bu 5 faturanın tekrar denenen gönderimleri; next = sonraki denemeye kadar bekleme):' -ForegroundColor Cyan
$simLog = @(Get-SimulatorLog | Where-Object { $_ -match 'Webhook send ' } | Where-Object { $line = $_; @($five | Where-Object { $line -match "invoice=$_ " }).Count -gt 0 })
$retriedIds = @($simLog | Where-Object { $_ -match 'outcome=Pending' } | ForEach-Object { if ($_ -match 'event=(\S+)') { $Matches[1] } } | Sort-Object -Unique)
$simLog | Where-Object { $line = $_; @($retriedIds | Where-Object { $line -match "event=$_ " }).Count -gt 0 } | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
$waits = @($simLog | Where-Object { $_ -match 'outcome=Pending' } | ForEach-Object { if ($_ -match 'attempt=(\d+)/6 .* next=(\d+)s') { "$($Matches[1])->$($Matches[2])" } } | Sort-Object -Unique)
Check (Write-DbVerdict 'bekleme süreleri görevdeki sırada (1. denemeden sonra 5 sn, 2.den sonra 10 sn ...)' ($waits -join ', ') `
    (@($waits | Where-Object { $_ -notin @('1->5', '2->10', '3->20', '4->40', '5->80') }).Count -eq 0 -and $waits.Count -ge 1))

Write-DbHeader 'B) Fatura Servisi'
Show-ServiceQuery "SELECT invoice_number, status, reject_reason FROM invoices WHERE invoice_number IN ($fiveList) ORDER BY invoice_number;"

Restart-Simulator
Write-Result $allPassed 'simülatör her fatura için iki imzalı haber gönderiyor, zamanlar aralıkta; servis kapalıyken tekrar deniyor ve sonunda hepsi kesin durumda'
