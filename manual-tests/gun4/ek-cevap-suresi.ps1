# Gün 4 - Haber kabul kuralı 6: servis her habere 5 saniye içinde cevap verecek. ~1,5 dk.
# Servis haberi ErpWebhooks:ResponseBudgetMilliseconds (4000) içinde kaydedip işleyemezse 503 döner; faturanın satır
# kilidini LockTimeoutMilliseconds'tan (2000) uzun bekleyemez. Üç durum:
#   A) Fatura satırı psql'den kilitli tutulur, o faturaya haber gönderilir: ~2 sn'de 503, tabloda kayıt yok.
#      Kilit bırakılınca aynı haber tekrar gönderilir: 200, bir kez işlenir.
#   B) Fatura veritabanı durdurulur (docker compose pause): ~4 sn'de 503. Veritabanı açılınca aynı haber: 200, bir kez işlenir.
#   C) Simülatörün kendi haberi kilitli faturaya gelir: 503 alır, simülatör tekrar gönderir, fatura sonunda kesin durumda.
#      (Kilit sürerken outbox da faturayı Gönderildi yapamaz; kilit bitince devam eder.)
. "$PSScriptRoot\_common.ps1"

$log = Join-Path $OutputDir ("gun4-ek-cevap-suresi-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -Path $log | Out-Null

$script:Paused = $false
trap { Write-Host "Hata: $_ - veritabanı ve simülatör eski haline döndürülüyor." -ForegroundColor Red
       if ($script:Paused) { try { Invoke-Compose @('unpause', 'invoice-db') | Out-Null } catch { } }
       Get-Job -Name 'satir-kilidi*' -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
       try { Restart-Simulator } catch { }
       Stop-Transcript | Out-Null; break }

Write-Title 'Kabul kuralı 6) Servis her habere 5 saniye içinde cevap veriyor'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

# Ayar dosyasındaki süreler (appsettings.json yorum içerdiği için regex).
$settingsText = Get-Content (Join-Path $RepoRoot 'invoice-service\src\InvoiceService.Api\appsettings.json') -Raw -Encoding UTF8
$budgetMs = [int]([regex]::Match($settingsText, '"ResponseBudgetMilliseconds"\s*:\s*(\d+)').Groups[1].Value)
$lockMs = [int]([regex]::Match($settingsText, '"LockTimeoutMilliseconds"\s*:\s*(\d+)').Groups[1].Value)
if ($budgetMs -le 0 -or $lockMs -le 0) { throw 'ResponseBudgetMilliseconds / LockTimeoutMilliseconds ayar dosyasında bulunamadı.' }
Write-Host "  Ayarlar: ResponseBudgetMilliseconds=$budgetMs, LockTimeoutMilliseconds=$lockMs (görev sınırı 5000 ms)"

$secret = Get-WebhookSecret
function Send-Event([string]$Json) {
    $body = [Text.Encoding]::UTF8.GetBytes($Json)
    $ts = "$(Get-UnixNow)"
    Send-Webhook $body $ts (Get-WebhookSignature $secret $ts $body)
}

# Faturanın satırını $Seconds saniye kilitli tutan ayrı bir psql oturumu (arka planda); kilit alınana kadar bekler.
function Start-RowLock([string]$Number, [int]$Seconds) {
    $sql = "BEGIN; SELECT invoice_number FROM invoices WHERE invoice_number = '$Number' FOR UPDATE; SELECT pg_sleep($Seconds); COMMIT;"
    $job = Start-Job -Name "satir-kilidi-$Number" -ArgumentList $RepoRoot, $sql -ScriptBlock {
        param($root, $sql)
        Set-Location $root
        & docker compose exec -T invoice-db psql -U invoice -d invoice_service -v ON_ERROR_STOP=1 -c $sql 2>&1
    }
    for ($i = 0; $i -lt 100; $i++) {
        if ((Count-Service "SELECT count(*) FROM pg_stat_activity WHERE wait_event = 'PgSleep';") -gt 0) { break }
        Start-Sleep -Milliseconds 200
    }
    if ($i -ge 100) { throw 'Satır kilidi 20 sn içinde alınamadı.' }
    Write-Host "  $Number satırı ayrı bir psql oturumunda $Seconds sn kilitli tutuluyor (SELECT ... FOR UPDATE; pg_sleep)." -ForegroundColor DarkGray
    $job
}

Wait-Service
$since = [datetime]::UtcNow.AddSeconds(-1)

# ---------------------------------------------------------------------------------------------------------------------
Write-Step 'A) Fatura satırı kilitliyken gelen haber'
Restart-Simulator (Get-SimSettings -NoEvents)
$numberA = @(New-Invoices 1)[0]
Wait-InvoicesIn @($numberA) @('Gönderildi') 30 'Gönderildi' | Out-Null
$refA = @(Get-ServiceRows "SELECT erp_reference FROM invoices WHERE invoice_number = '$numberA';")[0]
$eventA = "cevap-A-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$jsonA = New-WebhookBody $eventA 'invoice.received' $numberA $refA

$job = Start-RowLock $numberA 8
Write-DbHeader 'Fatura Servisi' 'Kilidi tutan oturum'
Show-ServiceQuery "SELECT pid, state, wait_event, left(query, 90) AS sorgu FROM pg_stat_activity WHERE wait_event = 'PgSleep';"
$a1 = Send-Event $jsonA
Write-Host "  $eventA (kilit varken) -> HTTP $($a1.Status), $($a1.Ms) ms"
$rowsA1 = Count-Service "SELECT count(*) FROM erp_webhook_events WHERE event_id = '$eventA';"
Check (Write-DbVerdict "HTTP 503, $lockMs ms'den sonra ve 5000 ms'den önce" "HTTP $($a1.Status), $($a1.Ms) ms" ($a1.Status -eq 503 -and $a1.Ms -ge $lockMs -and $a1.Ms -lt 5000))
Check (Write-DbVerdict 'erp_webhook_events''te 0 satır (transaction geri alındı)' $rowsA1 ($rowsA1 -eq 0))

Wait-Job $job | Out-Null; Remove-Job $job
$a2 = Send-Event $jsonA
Write-Host "  $eventA (kilit bırakıldıktan sonra, aynı haber) -> HTTP $($a2.Status), $($a2.Ms) ms, $($a2.Body)"
Write-DbHeader 'Fatura Servisi'
Show-ServiceQuery "SELECT event_id, status, delivery_count, to_char(received_at, 'HH24:MI:SS.MS') AS geldi FROM erp_webhook_events WHERE event_id = '$eventA';"
Show-ServiceQuery "SELECT invoice_number, status FROM invoices WHERE invoice_number = '$numberA';"
$rowA = @(Get-ServiceRows "SELECT status || '|' || delivery_count FROM erp_webhook_events WHERE event_id = '$eventA';")[0]
$statusA = @(Get-ServiceRows "SELECT status FROM invoices WHERE invoice_number = '$numberA';")[0]
Check (Write-DbVerdict 'HTTP 200, repeat=false' "HTTP $($a2.Status) $($a2.Body)" ($a2.Status -eq 200 -and $a2.Body -match '"repeat":false'))
Check (Write-DbVerdict 'haber İşlendi, delivery_count 1 (503 alan teslim kaydedilmemişti); fatura İşleme Alındı' "$rowA; fatura $statusA" ($rowA -eq 'İşlendi|1' -and $statusA -eq 'İşleme Alındı'))

# ---------------------------------------------------------------------------------------------------------------------
Write-Step 'B) Fatura veritabanı cevap vermezken gelen haber'
$eventB = "cevap-B-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$jsonB = New-WebhookBody $eventB 'invoice.approved' $numberA $refA
Invoke-Compose @('pause', 'invoice-db') | Out-Null
$script:Paused = $true
Write-Host '  invoice-db durduruldu (docker compose pause).' -ForegroundColor DarkGray
$b1 = Send-Event $jsonB
Write-Host "  $eventB (veritabanı durmuşken) -> HTTP $($b1.Status), $($b1.Ms) ms"
Check (Write-DbVerdict "HTTP 503, $budgetMs ms civarında ve 5000 ms'den önce" "HTTP $($b1.Status), $($b1.Ms) ms" ($b1.Status -eq 503 -and $b1.Ms -ge ($budgetMs - 100) -and $b1.Ms -lt 5000))
Start-Sleep -Seconds 1
Invoke-Compose @('unpause', 'invoice-db') | Out-Null
$script:Paused = $false
Write-Host '  invoice-db yeniden açıldı.' -ForegroundColor DarkGray
Start-Sleep -Seconds 3   # yarıda kalan iş geri alınsın / bağlantı kopsun

$b2 = Send-Event $jsonB
Write-Host "  $eventB (veritabanı açıldıktan sonra, aynı haber) -> HTTP $($b2.Status), $($b2.Ms) ms, $($b2.Body)"
Write-DbHeader 'Fatura Servisi'
Show-ServiceQuery "SELECT event_id, status, delivery_count FROM erp_webhook_events WHERE event_id = '$eventB';"
Show-ServiceQuery "SELECT invoice_number, status FROM invoices WHERE invoice_number = '$numberA';"
$rowB = @(Get-ServiceRows "SELECT count(*) || '|' || max(status) FROM erp_webhook_events WHERE event_id = '$eventB';")[0]
$statusB = @(Get-ServiceRows "SELECT status FROM invoices WHERE invoice_number = '$numberA';")[0]
Check (Write-DbVerdict 'HTTP 200' "HTTP $($b2.Status)" ($b2.Status -eq 200))
Check (Write-DbVerdict 'tabloda 1 satır, İşlendi; fatura bir kez ilerledi: Onaylandı' "$rowB; fatura $statusB" ($rowB -eq '1|İşlendi' -and $statusB -eq 'Onaylandı'))

# ---------------------------------------------------------------------------------------------------------------------
Write-Step 'C) Simülatörün kendi haberi kilitli faturaya geliyor'
# İlk haber kayıttan 5-8 sn sonra gelsin: fatura oluşturulur oluşturulmaz alınan 14 sn'lik kilit sürerken gelir.
$settingsC = Get-SimSettings
$settingsC['Webhooks__FirstEventMinSeconds'] = 5
$settingsC['Webhooks__FirstEventMaxSeconds'] = 8
Restart-Simulator $settingsC
$numberC = @(New-Invoices 1)[0]
$job = Start-RowLock $numberC 14
Wait-Job $job | Out-Null; Remove-Job $job
Wait-EventsDone @($numberC) 180 | Out-Null
Wait-InvoicesIn @($numberC) @('Onaylandı', 'Reddedildi') 60 'kesin durumda' | Out-Null

Write-DbHeader 'ERP Simulator' 'webhook_deliveries: her haberin deneme sayısı ve son HTTP kodu'
Show-ErpQuery "SELECT event_type, kind, status, attempt_count, last_http_status, to_char(first_sent_at, 'HH24:MI:SS.MS') AS ilk_gonderim, to_char(completed_at, 'HH24:MI:SS.MS') AS teslim FROM webhook_deliveries WHERE invoice_number = '$numberC' ORDER BY first_sent_at;"
$eventIdsC = @(Get-ErpRows "SELECT DISTINCT event_id FROM webhook_deliveries WHERE invoice_number = '$numberC';")
$patternC = ($eventIdsC | ForEach-Object { [regex]::Escape($_) }) -join '|'
$log503 = @(Get-WebhookLog $since | Where-Object { $_ -match 'http=503' -and $_ -match $patternC })
Write-Host ''
Write-Host '  Servis logundaki 503 satırları:' -ForegroundColor Cyan
$log503 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
$retried = Count-Erp "SELECT count(*) FROM webhook_deliveries WHERE invoice_number = '$numberC' AND attempt_count > 1 AND status = 'Delivered';"
$undelivered = Count-Erp "SELECT count(*) FROM webhook_deliveries WHERE invoice_number = '$numberC' AND status <> 'Delivered';"
$statusC = @(Get-ServiceRows "SELECT status FROM invoices WHERE invoice_number = '$numberC';")[0]
Write-DbHeader 'Fatura Servisi'
Show-ServiceQuery "SELECT event_type, status, delivery_count FROM erp_webhook_events WHERE invoice_number = '$numberC' ORDER BY received_at;"
Check (Write-DbVerdict 'servis kilit varken gelen haberlere 503 döndü (logda en az 1)' "$($log503.Count) satır" ($log503.Count -ge 1))
Check (Write-DbVerdict 'simülatör 503 alan haberi tekrar gönderdi ve teslim etti; teslim edilmeyen haber 0' "tekrar denemeyle teslim: $retried, teslim edilmeyen: $undelivered" ($retried -ge 1 -and $undelivered -eq 0))
Check (Write-DbVerdict 'fatura kesin durumda' $statusC ($statusC -in @('Onaylandı', 'Reddedildi')))

# ---------------------------------------------------------------------------------------------------------------------
Write-Step 'Servis logu: bu testteki bütün 503 satırları'
@(Get-WebhookLog $since | Where-Object { $_ -match 'http=503|after its 503' }) | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

Restart-Simulator
Write-Result $allPassed 'cevap süresi sınırı: kilit ve veritabanı beklemesinde 5 sn dolmadan 503; tekrar gelen haber bir kez işlendi'
Write-Host "Log: $log"
Stop-Transcript | Out-Null
