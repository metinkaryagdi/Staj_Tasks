# Gün 4 - Kontrol listesi 3: varsayılan oranlarla (appsettings.json: POST davranışları ve haber sorunları) 500 fatura,
# bütün haberler gelene kadar bekle, sonucu tabloyla ver. ~4 dk.
#
# Sayıların kaynağı:
#   - Fatura durumları, tekrar gelen ve Yok Sayıldı haberler: Fatura Servisi veritabanı (invoices, erp_webhook_events).
#   - Karar haberini hiç göndermediği fatura, sahte ve eski haberler: simülatörün webhook_deliveries tablosu
#     (kind LostDecision / Fake / Replay); 401 sayıları ayrıca servis logundaki reddetme satırlarıyla karşılaştırılır
#     (401 alan haber tabloya yazılmadığı için serviste iz yalnızca log).
#   - Durumu geri giden fatura: servis logundaki her durum değişimi (invoiceStatus=A->B) ve veritabanında
#     "işlenmiş en ileri haber faturanın durumundan ileride mi" kontrolü.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: $_ - simülatör varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Restart-Simulator } catch { }; break }

Write-Title 'Kontrol listesi 3) Varsayılan oranlar, 500 fatura'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
Restart-Simulator
$since = [datetime]::UtcNow.AddSeconds(-1)
$numbers = New-Invoices 500
$list = InList $numbers

Write-Step 'Fatura Servisi''nin kuyruğunun boşalması bekleniyor (Bekliyor kalmayana kadar)'
$s1 = Wait-InvoicesIn $numbers @('Gönderildi', 'İşleme Alındı', 'Onaylandı', 'Reddedildi', 'Başarısız') 600 'gönderilmiş'
Write-Host "  kuyruk $s1 sn'de boşaldı"
Write-Step 'Simülatörün bütün haberleri göndermesi bekleniyor (tekrar denemeler dahil)'
$s2 = Wait-EventsDone $numbers 600
Write-Host "  $s2 sn sonra simülatörde gönderilecek haber kalmadı"

# --- Sayılar -----------------------------------------------------------------------------------------------------------
$status = @{}
Get-ServiceRows "SELECT status, count(*) FROM invoices WHERE invoice_number IN ($list) GROUP BY status;" | ForEach-Object { $p = $_ -split '\|'; $status[$p[0]] = [int]$p[1] }
$approved = [int]$status['Onaylandı']; $rejected = [int]$status['Reddedildi']
$stuck = [int]$status['Gönderildi'] + [int]$status['İşleme Alındı']
$failed = [int]$status['Başarısız']; $pending = [int]$status['Bekliyor']

# Kararı hiç gönderilmeyen fatura: simülatörde bu numaranın HİÇBİR kaydı karar göndermemişse (aynı numaranın iki ERP kaydı
# olabilir; ikincisinin haberleri farklı erp_reference ile gelip Yok Sayılır, faturayı ilerletmez).
# Servisin Başarısız bıraktığı fatura (ERP'ye ulaştığını bilmiyor) bu karşılaştırmanın dışında; ayrıca gösterilir.
$failedNumbers = @(Get-ServiceRows "SELECT invoice_number FROM invoices WHERE invoice_number IN ($list) AND status = 'Başarısız';")
$lostNumbers = @(Get-ErpRows ("SELECT DISTINCT w.invoice_number FROM webhook_deliveries w WHERE w.invoice_number IN ($list) AND w.kind = 'LostDecision' " +
    "AND NOT EXISTS (SELECT 1 FROM webhook_deliveries x WHERE x.invoice_number = w.invoice_number AND x.kind = 'Normal' " +
    "AND x.event_type <> 'invoice.received' AND x.status = 'Delivered' " +
    "AND x.invoice_id = (SELECT min(id) FROM invoices WHERE invoice_number = w.invoice_number)) ORDER BY 1;") |
    Where-Object { $failedNumbers -notcontains $_ })
$lost = $lostNumbers.Count
$stuckNumbers = @(Get-ServiceRows "SELECT invoice_number FROM invoices WHERE invoice_number IN ($list) AND status IN ('Gönderildi', 'İşleme Alındı') ORDER BY 1;")

$fake = @(Get-ErpRows "SELECT count(*) || '|' || count(*) FILTER (WHERE status = 'Rejected' AND last_http_status = 401) || '|' || coalesce(max(attempt_count), 0) FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'Fake';")[0] -split '\|'
$replay = @(Get-ErpRows "SELECT count(*) || '|' || count(*) FILTER (WHERE status = 'Rejected' AND last_http_status = 401) || '|' || coalesce(max(attempt_count), 0) FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'Replay';")[0] -split '\|'
$replaySkipped = Count-Erp "SELECT count(*) FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'Replay' AND status = 'Skipped';"
$replayWaiting = Count-Erp "SELECT count(*) FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'Replay' AND status = 'Waiting';"
$log = @(Get-WebhookLog $since)
$logFake = @($log | Where-Object { $_ -match 'http=401 reason=bad-signature' }).Count
$logReplay = @($log | Where-Object { $_ -match 'http=401 reason=expired' }).Count

$repeats = Count-Service "SELECT coalesce(sum(delivery_count - 1), 0) FROM erp_webhook_events WHERE invoice_number IN ($list);"
$simDuplicates = Count-Erp "SELECT count(*) FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'Duplicate' AND status = 'Delivered';"
$ignored = @{}
Get-ServiceRows "SELECT ignore_reason, count(*) FROM erp_webhook_events WHERE invoice_number IN ($list) AND status = 'Yok Sayıldı' GROUP BY 1;" | ForEach-Object { $p = $_ -split '\|'; $ignored[$p[0]] = [int]$p[1] }
$backwardEvents = [int]$ignored['Geri Götürüyor']

$transitions = Get-BackwardTransitions $numbers $since
$dbBackward = Count-Service ("SELECT count(*) FROM invoices i WHERE i.invoice_number IN ($list) AND " +
    "(CASE i.status WHEN 'Onaylandı' THEN 3 WHEN 'Reddedildi' THEN 3 WHEN 'İşleme Alındı' THEN 2 WHEN 'Gönderildi' THEN 1 ELSE 0 END) < " +
    "(SELECT coalesce(max(CASE e.event_type WHEN 'invoice.received' THEN 2 ELSE 3 END), 0) FROM erp_webhook_events e WHERE e.invoice_number = i.invoice_number AND e.status = 'İşlendi');")
$backwardInvoices = @($transitions.Backward | ForEach-Object { if ($_ -match ' invoice=(\S+) ') { $Matches[1] } } | Sort-Object -Unique).Count + $dbBackward

# --- Tablo -------------------------------------------------------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 100) -ForegroundColor Cyan
Write-Host ' KONTROL LİSTESİ 3 - SONUÇ TABLOSU (500 fatura, varsayılan oranlar)' -ForegroundColor Cyan
Write-Host ('=' * 100) -ForegroundColor Cyan
$rows = @(
    @('Onaylandı', $approved),
    @('Reddedildi', $rejected),
    @('Gönderildi ya da İşleme Alındı''da kalan fatura', $stuck),
    @('Simülatörün karar haberini hiç göndermediği fatura', $lost),
    @('401 ile reddedilen sahte haber', $fake[1]),
    @('401 ile reddedilen eski haber', $replay[1]),
    @('Tekrar geldiği için yeniden işlenmeyen haber', $repeats),
    @('Durumu geri götürdüğü için Yok Sayıldı olan haber', $backwardEvents),
    @('Durumu geri giden fatura', $backwardInvoices)
)
foreach ($r in $rows) { Write-Host ('  {0,-60} {1,6}' -f $r[0], $r[1]) }
Write-Host ''
Write-Host '  Ek bilgiler:' -ForegroundColor DarkGray
Write-Host ('    Başarısız (ERP''ye gönderilemedi): {0}, Bekliyor: {1}; toplam fatura {2}' -f $failed, $pending, ($approved + $rejected + $stuck + $failed + $pending)) -ForegroundColor DarkGray
Write-Host ('    Sahte haber: simülatör {0} gönderdi, {1} tanesi 401 aldı, en çok {2} deneme; servis logunda bad-signature {3}' -f $fake[0], $fake[1], $fake[2], $logFake) -ForegroundColor DarkGray
Write-Host ('    Eski haber: simülatör {0} gönderdi, {1} tanesi 401 aldı, en çok {2} deneme; servis logunda expired {3}' -f $replay[0], $replay[1], $replay[2], $logReplay) -ForegroundColor DarkGray
Write-Host ("    Eski haber: Skipped $replaySkipped, Waiting $replayWaiting (servis açıkken ikisi de 0 olmalı)") -ForegroundColor DarkGray
Write-Host ('    Tekrar: simülatörün bilerek çift gönderdiği ve ulaşan {0}; servisin saydığı tekrar {1}' -f $simDuplicates, $repeats) -ForegroundColor DarkGray
Write-Host ('    Yok Sayıldı nedenleri: Geri Götürüyor {0}, Kesin Durumda {1}, İlerletmiyor {2}, Referans Farklı {3}' -f `
    [int]$ignored['Geri Götürüyor'], [int]$ignored['Kesin Durumda'], [int]$ignored['İlerletmiyor'], [int]$ignored['Referans Farklı']) -ForegroundColor DarkGray
Write-Host ('    Geri gidiş kontrolü: logdaki {0} durum değişiminin {1} tanesi geri; veritabanında durumu işlenmiş haberinin gerisinde kalan fatura {2}' -f `
    $transitions.Checked, $transitions.Backward.Count, $dbBackward) -ForegroundColor DarkGray
Write-Host ('    Kalan faturalar: {0}' -f ($stuckNumbers -join ', ')) -ForegroundColor DarkGray
Write-Host ('    Kararı kayıp faturalar: {0}' -f ($lostNumbers -join ', ')) -ForegroundColor DarkGray
Write-Host ('    Başarısız faturalar: {0}' -f ($(if ($failedNumbers.Count) { $failedNumbers -join ', ' } else { '-' }))) -ForegroundColor DarkGray
Write-Host ("    Süre: kuyruk {0} sn, haberler bundan {1} sn sonra bitti" -f $s1, $s2) -ForegroundColor DarkGray

Write-DbHeader 'Kontroller'
Check (Write-DbVerdict 'kalan fatura sayısı = kararı gönderilmeyen fatura sayısı' "$stuck = $lost" ($stuck -eq $lost))
Check (Write-DbVerdict 'kalan faturalar ile kararı kayıp faturalar aynı faturalar' (($stuckNumbers -join ',') -eq ($lostNumbers -join ',')) (($stuckNumbers -join ',') -eq ($lostNumbers -join ',')))
Check (Write-DbVerdict 'sahte haberlerin hepsi 401 aldı ve tekrar gönderilmedi; logla aynı sayı' "$($fake[1])/$($fake[0]), en çok $($fake[2]) deneme, log $logFake" ($fake[0] -eq $fake[1] -and [int]$fake[2] -le 1 -and $logFake -eq [int]$fake[1]))
Check (Write-DbVerdict 'eski haberlerin hepsi 401 aldı ve tekrar gönderilmedi; logla aynı sayı' "$($replay[1])/$($replay[0]), en çok $($replay[2]) deneme, log $logReplay" ($replay[0] -eq $replay[1] -and [int]$replay[2] -le 1 -and $logReplay -eq [int]$replay[1]))
Check (Write-DbVerdict 'tekrar gelen haber en az simülatörün çift gönderdiği kadar' "$repeats >= $simDuplicates" ($repeats -ge $simDuplicates))
Check (Write-DbVerdict 'durumu geri giden fatura 0' "$backwardInvoices" ($backwardInvoices -eq 0))
Check (Write-DbVerdict 'Bekliyor fatura kalmadı' "$pending" ($pending -eq 0))
Check (Write-DbVerdict 'servis açıkken Skipped / Waiting eski haber 0 / 0' "$replaySkipped / $replayWaiting" ($replaySkipped -eq 0 -and $replayWaiting -eq 0))

Write-Result $allPassed 'tablo yukarıda; kalan fatura = kararı gönderilmeyen fatura, sahte/eski haberler 401, geri giden fatura 0'
