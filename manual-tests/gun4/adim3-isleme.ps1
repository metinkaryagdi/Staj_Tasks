# Gün 4 - Adım 3 ve 4: haberin kaydedilmesi, faturaya işlenmesi, tekrarın önlenmesi ve faturadan önce gelen haber. ~2 dk.
# Simülatör henüz haber göndermiyor (Adım 5); haberleri bu script imzalayıp gönderiyor.
#
#   A) Fatura 1 (Gönderildi): invoice.received -> İşleme Alındı; aynı haber tekrar -> 200, işlenmez, delivery_count 2;
#      invoice.approved -> Onaylandı; sonradan invoice.received -> Yok Sayıldı (Geri Götürüyor); invoice.rejected ->
#      Yok Sayıldı (Kesin Durumda). Fatura Onaylandı kalır.
#   B) Fatura 2 (Gönderildi): doğrudan invoice.rejected -> Reddedildi, reject_reason dolu.
#   C) Fatura 3 (Gönderildi): erp_reference farklı -> Yok Sayıldı (Referans Farklı) + uyarı logu, fatura değişmez.
#   D) Kontrol listesi 8: fatura 4 için aynı haber aynı anda 10 kez paralel -> 10'u da 200, tabloda 1 satır
#      (İşlendi, delivery_count 10), logda 1 "stored" + 9 "repeat", fatura İşleme Alındı.
#   E) Faturadan önce gelen haber (Adım 4): simülatör LateResponse %100 -> servis 10 sn'de vazgeçer, fatura Bekliyor kalır.
#      Simülatör faturayı kaydettiği anda referansını okuyup received + approved gönderilir -> ikisi de Bekliyor.
#      Servis tekrar denediğinde faturayı simülatörde bulur, Gönderildi yapar ve bekleyen haberleri aynı transaction'da
#      sırayla işler -> İşleme Alındı -> Onaylandı. Haberlerin Gönderildi'den önce geldiği loglarla gösterilir.
#   F) Serviste hiç olmayan bir fatura için haber -> 200, Bekliyor (kaybolmaz).
#
# Sonunda simülatör varsayılan ayarlarına döner.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: $_ - simülatör varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Restart-Simulator } catch { }; break }

Write-Title 'Adım 3-4) Haberin işlenmesi, tekrar, paralel gönderim (kontrol listesi 8) ve faturadan önce gelen haber'
$secret = Get-WebhookSecret
$prefix = New-Prefix 'adim3'
$startedAt = [datetime]::UtcNow.AddSeconds(-2)
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

$success = @{ Simulator__Rates__Success = 100; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0
              Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0 }

function Send-Event([string]$Id, [string]$Type, [string]$Invoice, [string]$Reference, [string]$Reason) {
    $body = [Text.Encoding]::UTF8.GetBytes((New-WebhookBody "$prefix$Id" $Type $Invoice $Reference $Reason))
    $ts = "$(Get-UnixNow)"
    $r = Send-Webhook $body $ts (Get-WebhookSignature $secret $ts $body)
    $status = if ($r.Body -match '"status":"([^"]+)"') { $Matches[1] } else { '-' }
    $repeat = $r.Body -match '"repeat":true'
    Write-Host ('  {0,-4} {1,-17} {2} ref={3,-14} -> HTTP {4}, haber {5}{6}, {7} ms' -f $Id, $Type, $Invoice, $Reference, $r.Status, $status,
        $(if ($repeat) { ' (tekrar)' } else { '' }), $r.Ms)
    [pscustomobject]@{ Status = $r.Status; EventStatus = $status; Repeat = $repeat; Ms = $r.Ms }
}

function Get-InvoiceRow([string]$Number) {
    $row = @(Get-ServiceRows "SELECT status, coalesce(erp_reference, '-'), coalesce(reject_reason, '-') FROM invoices WHERE invoice_number = '$Number';")[0] -split '\|'
    [pscustomobject]@{ Status = $row[0]; Reference = $row[1]; RejectReason = $row[2] }
}

function Wait-InvoiceStatus([string]$Number, [string]$Status, [int]$TimeoutSeconds = 90) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ((Get-InvoiceRow $Number).Status -ne $Status) {
        if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw "$Number $TimeoutSeconds sn içinde $Status olmadı." }
        Start-Sleep -Milliseconds 300
    }
}

function Show-Events([string]$Like) {
    Show-ServiceQuery ("SELECT event_id, event_type, invoice_number, status, ignore_reason, delivery_count, " +
        "to_char(received_at, 'HH24:MI:SS.MS') AS received, to_char(processed_at, 'HH24:MI:SS.MS') AS processed " +
        "FROM erp_webhook_events WHERE event_id LIKE '$Like' ORDER BY received_at;")
}

Wait-Service
Restart-Simulator $success

Write-Step 'Hazırlık: 4 fatura oluşturulup Gönderildi olması bekleniyor'
$inv = @()
for ($i = 1; $i -le 4; $i++) { $inv += (New-ServiceInvoice).InvoiceNumber }
foreach ($n in $inv) { Wait-InvoiceStatus $n 'Gönderildi' }
$ref = @{}
foreach ($n in $inv) { $ref[$n] = (Get-InvoiceRow $n).Reference; Write-Host "  $n Gönderildi, erp_reference=$($ref[$n])" }

# --- A) ----------------------------------------------------------------------------------------------------------------
Write-Step "A) $($inv[0]): ileri giden haberler işlenir, tekrar ve geri götüren haber işlenmez"
$a1 = Send-Event 'A1' 'invoice.received' $inv[0] $ref[$inv[0]]
$s1 = (Get-InvoiceRow $inv[0]).Status
$a1b = Send-Event 'A1' 'invoice.received' $inv[0] $ref[$inv[0]]
$a2 = Send-Event 'A2' 'invoice.approved' $inv[0] $ref[$inv[0]]
$a3 = Send-Event 'A3' 'invoice.received' $inv[0] $ref[$inv[0]]
$a4 = Send-Event 'A4' 'invoice.rejected' $inv[0] $ref[$inv[0]] 'Geç gelen red'
Show-Events "${prefix}A%"
$row = Get-InvoiceRow $inv[0]
Write-DbHeader "A) $($inv[0])"
Check (Write-DbVerdict 'received sonrası fatura İşleme Alındı' $s1 ($s1 -eq 'İşleme Alındı'))
Check (Write-DbVerdict 'aynı haber tekrar: 200, tekrar=evet' "HTTP $($a1b.Status), tekrar=$($a1b.Repeat)" ($a1b.Status -eq 200 -and $a1b.Repeat))
$dc = @(Get-ServiceRows "SELECT delivery_count FROM erp_webhook_events WHERE event_id = '${prefix}A1';")[0]
Check (Write-DbVerdict 'A1 delivery_count 2, tabloda tek satır' "delivery_count $dc" ($dc -eq '2'))
$a3r = @(Get-ServiceRows "SELECT status || '|' || ignore_reason FROM erp_webhook_events WHERE event_id = '${prefix}A3';")[0]
Check (Write-DbVerdict 'karardan sonra gelen received: Yok Sayıldı|Geri Götürüyor' $a3r ($a3r -eq 'Yok Sayıldı|Geri Götürüyor'))
$a4r = @(Get-ServiceRows "SELECT status || '|' || ignore_reason FROM erp_webhook_events WHERE event_id = '${prefix}A4';")[0]
Check (Write-DbVerdict 'onaydan sonra gelen red: Yok Sayıldı|Kesin Durumda' $a4r ($a4r -eq 'Yok Sayıldı|Kesin Durumda'))
Check (Write-DbVerdict 'fatura Onaylandı, reject_reason boş' "$($row.Status), reject_reason=$($row.RejectReason)" ($row.Status -eq 'Onaylandı' -and $row.RejectReason -eq '-'))

# --- B) ----------------------------------------------------------------------------------------------------------------
Write-Step "B) $($inv[1]): Gönderildi'den doğrudan red"
Send-Event 'B1' 'invoice.rejected' $inv[1] $ref[$inv[1]] 'Vergi numarası geçersiz' | Out-Null
$row = Get-InvoiceRow $inv[1]
Write-DbHeader "B) $($inv[1])"
Check (Write-DbVerdict 'Reddedildi, reject_reason = Vergi numarası geçersiz' "$($row.Status), reject_reason=$($row.RejectReason)" `
    ($row.Status -eq 'Reddedildi' -and $row.RejectReason -eq 'Vergi numarası geçersiz'))

# --- C) ----------------------------------------------------------------------------------------------------------------
Write-Step "C) $($inv[2]): erp_reference faturadakinden farklı"
Send-Event 'C1' 'invoice.approved' $inv[2] 'ERP-BASKA-KAYIT' | Out-Null
$row = Get-InvoiceRow $inv[2]
$c1 = @(Get-ServiceRows "SELECT status || '|' || ignore_reason FROM erp_webhook_events WHERE event_id = '${prefix}C1';")[0]
Write-DbHeader "C) $($inv[2])"
Check (Write-DbVerdict 'haber Yok Sayıldı|Referans Farklı, fatura Gönderildi kalır' "$c1, fatura $($row.Status)" `
    ($c1 -eq 'Yok Sayıldı|Referans Farklı' -and $row.Status -eq 'Gönderildi'))
Start-Sleep -Milliseconds 300
$warn = @(Get-WebhookLog $startedAt | Where-Object { $_ -match "warn: .*event=${prefix}C1 .*ignoreReason=Referans Farklı" })
$warn | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
Check (Write-DbVerdict 'uyarı (warn) logu var' "$($warn.Count) satır" ($warn.Count -eq 1))

# --- D) Kontrol listesi 8 ----------------------------------------------------------------------------------------------
Write-Step "D) Kontrol listesi 8: $($inv[3]) için aynı haber aynı anda 10 kez paralel"
$body = [Text.Encoding]::UTF8.GetBytes((New-WebhookBody "${prefix}D1" 'invoice.received' $inv[3] $ref[$inv[3]]))
$ts = "$(Get-UnixNow)"
$sig = Get-WebhookSignature $secret $ts $body
$tasks = @()
for ($i = 0; $i -lt 10; $i++) {
    $request = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post, "$ServiceUrl/api/v1/erp-webhooks")
    $request.Content = New-Object System.Net.Http.ByteArrayContent (,$body)
    $request.Content.Headers.ContentType = 'application/json'
    [void]$request.Headers.TryAddWithoutValidation('X-Erp-Timestamp', $ts)
    [void]$request.Headers.TryAddWithoutValidation('X-Erp-Signature', $sig)
    $tasks += $script:Http.SendAsync($request)
}
[Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks)
$codes = @($tasks | ForEach-Object { [int]$_.Result.StatusCode })
$bodies = @($tasks | ForEach-Object { $_.Result.Content.ReadAsStringAsync().GetAwaiter().GetResult() })
Write-Host "  HTTP kodları: $($codes -join ', ')"
Write-Host "  tekrar=false olan cevap: $(@($bodies | Where-Object { $_ -match '"repeat":false' }).Count), tekrar=true: $(@($bodies | Where-Object { $_ -match '"repeat":true' }).Count)"
Show-Events "${prefix}D%"
Start-Sleep -Milliseconds 300
$dLog = @(Get-WebhookLog $startedAt | Where-Object { $_ -match "event=${prefix}D1 " })
$dLog | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
$row = Get-InvoiceRow $inv[3]
$d = @(Get-ServiceRows "SELECT count(*) || '|' || max(status) || '|' || max(delivery_count) FROM erp_webhook_events WHERE event_id = '${prefix}D1';")[0]
Write-DbHeader 'D) Kontrol listesi 8'
Check (Write-DbVerdict '10 istek de 200' ($codes -join ',') (@($codes | Where-Object { $_ -ne 200 }).Count -eq 0 -and $codes.Count -eq 10))
Check (Write-DbVerdict 'tabloda 1 satır | İşlendi | delivery_count 10' $d ($d -eq '1|İşlendi|10'))
Check (Write-DbVerdict 'logda 1 stored, 9 repeat' "$(@($dLog | Where-Object { $_ -match 'webhook stored' }).Count) stored, $(@($dLog | Where-Object { $_ -match 'webhook repeat' }).Count) repeat" `
    (@($dLog | Where-Object { $_ -match 'webhook stored' }).Count -eq 1 -and @($dLog | Where-Object { $_ -match 'webhook repeat' }).Count -eq 9))
Check (Write-DbVerdict 'fatura İşleme Alındı (bir kez işlendi)' $row.Status ($row.Status -eq 'İşleme Alındı'))

# --- E) Faturadan önce gelen haber ------------------------------------------------------------------------------------
Write-Step 'E) Faturadan önce gelen haber: simülatör LateResponse %100 (30 sn geç cevap, servis 10 sn''de vazgeçer)'
Restart-Simulator @{ Simulator__Rates__Success = 0; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0
                     Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 100 }
$late = (New-ServiceInvoice).InvoiceNumber
Write-Host "  $late oluşturuldu; simülatörün kaydetmesi bekleniyor..."
$watch = [Diagnostics.Stopwatch]::StartNew()
# Simülatörün veritabanından okunur (HTTP değil): yeniden oluşturulan container'a eski bağlantıdan giden istek
# saniyelerce asılı kalabiliyor ve servis 10 sn'lik pencereyi kaçırtıyor.
do {
    Start-Sleep -Milliseconds 100
    $lateRef = @(Get-ErpRows "SELECT erp_reference FROM invoices WHERE invoice_number = '$late' ORDER BY id LIMIT 1;")[0]
    if ($watch.Elapsed.TotalSeconds -gt 20) { throw "$late simülatörde 20 sn içinde görünmedi." }
} while (-not $lateRef)
$beforeStatus = (Get-InvoiceRow $late).Status
Write-Host "  simülatör kaydetti: erp_reference=$lateRef; servisteki durum: $beforeStatus"
$e1 = Send-Event 'E1' 'invoice.received' $late $lateRef
$e2 = Send-Event 'E2' 'invoice.approved' $late $lateRef
Write-DbHeader 'E) haberler geldiğinde'
Check (Write-DbVerdict 'fatura henüz Gönderildi değil; iki haber 200 ve Bekliyor' "fatura $beforeStatus; $($e1.Status)/$($e1.EventStatus), $($e2.Status)/$($e2.EventStatus)" `
    ($beforeStatus -eq 'Bekliyor' -and $e1.Status -eq 200 -and $e2.Status -eq 200 -and $e1.EventStatus -eq 'Bekliyor' -and $e2.EventStatus -eq 'Bekliyor'))
Write-Host '  servis tekrar deneyip faturayı simülatörde bulana kadar bekleniyor...'
Wait-InvoiceStatus $late 'Onaylandı' 120
Show-Events "${prefix}E%"
Start-Sleep -Milliseconds 300
Write-Host ''
Write-Host '  Servis logu (zaman sırasıyla): haberler -> Gönderildi -> bekleyen haberler işlendi' -ForegroundColor Cyan
$eLog = @(Get-ServiceLog | Where-Object { $_ -match "event=${prefix}E\d|ERP send invoice=$late " })
$eLog | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
$storedLines = @($eLog | Where-Object { $_ -match 'webhook stored .*status=Bekliyor' })
$sentLine = @($eLog | Where-Object { $_ -match "ERP send invoice=$late .*outcome=Sent" })
$appliedLines = @($eLog | Where-Object { $_ -match 'webhook applied-after-send' })
# Outbox kendi "outcome=Sent" satırını transaction commit edildikten sonra yazar; bekleyen haberler o transaction'ın
# içinde işlendiği için onların satırları önce görünür. Sıra kanıtı: haberler fatura Bekliyor iken kaydedildi
# (invoiceStatus=Bekliyor->Bekliyor), sonra fatura Gönderildi iken işlendi (ilk applied satırı Gönderildi->...).
$order = $storedLines.Count -eq 2 -and $sentLine.Count -eq 1 -and $appliedLines.Count -eq 2 -and
    @($storedLines | Where-Object { $_ -match 'invoiceStatus=Bekliyor->Bekliyor' }).Count -eq 2 -and
    ([array]::IndexOf($eLog, $storedLines[1]) -lt [array]::IndexOf($eLog, $appliedLines[0])) -and
    $appliedLines[0] -match 'invoiceStatus=Gönderildi->İşleme Alındı' -and
    $appliedLines[1] -match 'invoiceStatus=İşleme Alındı->Onaylandı'
$e =@(Get-ServiceRows "SELECT string_agg(event_type || '=' || status, ',' ORDER BY occurred_at) FROM erp_webhook_events WHERE event_id LIKE '${prefix}E%';")[0]
Write-DbHeader 'E) sonunda'
Check (Write-DbVerdict 'logda: 2 haber fatura Bekliyor iken kaydedildi -> fatura Gönderildi -> 2 haber applied-after-send (Gönderildi->İşleme Alındı->Onaylandı)' "$($storedLines.Count) stored, $($sentLine.Count) Sent, $($appliedLines.Count) applied, sıra doğru: $order" $order)
Check (Write-DbVerdict 'iki haber de İşlendi, fatura Onaylandı' "$e; fatura $((Get-InvoiceRow $late).Status)" `
    ($e -eq 'invoice.received=İşlendi,invoice.approved=İşlendi' -and (Get-InvoiceRow $late).Status -eq 'Onaylandı'))

# --- F) ----------------------------------------------------------------------------------------------------------------
Write-Step 'F) Serviste olmayan fatura için haber'
$f = Send-Event 'F1' 'invoice.received' 'FTR-YOK-0001' 'ERP-YOK'
Check (Write-DbVerdict '200 ve Bekliyor (kaybolmaz)' "HTTP $($f.Status), $($f.EventStatus)" ($f.Status -eq 200 -and $f.EventStatus -eq 'Bekliyor'))

Restart-Simulator
Write-Result $allPassed 'haberler ileri yönde işleniyor; tekrar, geri götüren ve referansı farklı haber faturayı değiştirmiyor; paralel 10 istekten biri işleniyor; faturadan önce gelen haber Gönderildi olunca işleniyor'
