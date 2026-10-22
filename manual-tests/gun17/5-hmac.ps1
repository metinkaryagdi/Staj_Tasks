# Kontrol listesi 5: ERP'den gelen haberler HMAC ile eskisi gibi işleniyor; webhook JWT istemiyor. Açık yığında çalışır
# (1-hazir.ps1'den sonra, veritabanları boş başlamış olarak). ~1 dk.
#   A) Elle: doğru imzalı haber token'sız 200; yanlış imza 401; token var HMAC yok 401.
#   B) Simülatörün kendi haberleri: doğru imzalılar (Normal, Duplicate) kabul ediliyor, hiçbiri 401 almıyor; simülatörün bilerek
#      eski zaman damgasıyla (Replay) ya da yanlış anahtarla (Fake) gönderdikleri 401 ile reddediliyor (simülatör 4xx alınca
#      bunları tekrar denemez). Servis haberleri işliyor.
#   .\manual-tests\gun17\5-hmac.ps1
. "$PSScriptRoot\_common.ps1"

New-Report 'gun17-5-hmac'
Write-Title 'Kontrol listesi 5) ERP haberleri HMAC ile işleniyor'
Wait-KeycloakAndService
$allPassed = $true
function Check([bool]$Passed, [string]$Text) {
    Write-Line ("  [{0}] {1}" -f $(if ($Passed) { 'TAMAM' } else { 'FARKLI' }), $Text)
    if (-not $Passed) { $script:allPassed = $false }
}

Write-Line 'A) Elle gönderilen haberler (POST /api/v1/erp-webhooks, Authorization yok):'
$secret = Get-WebhookSecret
$eventId = "gun17-hmac-$(Get-Date -Format 'HHmmss')"
$body = [Text.Encoding]::UTF8.GetBytes((New-WebhookBody $eventId 'invoice.received' 'FTR-GUN17-HMAC' 'ERP-GUN17' $null))
$ts = [string](Get-UnixNow)
$valid = Send-Webhook $body $ts (Get-WebhookSignature $secret $ts $body)
Check ($valid.Status -eq 200) "doğru imza, token yok: HTTP $($valid.Status) $($valid.Body)"
$wrong = Send-Webhook $body $ts (Get-WebhookSignature 'not-the-secret-not-the-secret-not-the-secret' $ts $body)
Check ($wrong.Status -eq 401) "yanlış imza: HTTP $($wrong.Status)"
$jwtOnly = Send-Api POST '/api/v1/erp-webhooks' (Get-UserToken 'operator') '{}'
Check ($jwtOnly.Status -eq 401) "operatör token'ı var, HMAC başlıkları yok: HTTP $($jwtOnly.Status) (JWT webhook'u açmıyor)"
$stored = [int]@(Get-ServiceRows "SELECT count(*) FROM erp_webhook_events WHERE event_id = '$eventId';")[0]
Check ($stored -eq 1) "doğru imzalı haber erp_webhook_events'e bir kez yazıldı ($stored satır)"

Write-Line ''
Write-Line 'B) Simülatörün gönderdiği haberler (veritabanları 1-hazir.ps1''de boş başladı):'
$sim = @(Get-ErpRows "SELECT kind, status, coalesce(last_http_status::text, '-'), count(*) FROM webhook_deliveries WHERE first_sent_at IS NOT NULL GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;")
Write-Line '  Simülatör (webhook_deliveries, gönderilmiş olanlar): tür | durum | son HTTP | adet'
foreach ($row in $sim) { Write-Line "    $row" }
$events = @(Get-ServiceRows 'SELECT status, count(*) FROM erp_webhook_events GROUP BY 1 ORDER BY 1;')
Write-Line '  Servis (erp_webhook_events): durum | adet'
foreach ($row in $events) { Write-Line "    $row" }
$reasons = @(Get-WebhookLog | ForEach-Object { if ($_ -match 'ERP webhook rejected http=401 reason=(\S+)') { $Matches[1] } })
Write-Line '  Servis logundaki 401 nedenleri (bilgi için; elle gönderilen yanlış imzalı ve HMAC''sız istekler de dahil):'
foreach ($g in ($reasons | Group-Object | Sort-Object Name)) { Write-Line "    $($g.Name): $($g.Count)" }

function Get-Sum([string]$Pattern) { [int](@($sim | Where-Object { $_ -match $Pattern } | ForEach-Object { ($_ -split '\|')[3] }) | Measure-Object -Sum).Sum }
$signedOk = Get-Sum '^(Normal|Duplicate|LostDecision)\|'
$signedOk401 = Get-Sum '^(Normal|Duplicate|LostDecision)\|[^|]+\|401\|'
$bad = Get-Sum '^(Replay|Fake)\|'
$badRejected = Get-Sum '^(Replay|Fake)\|Rejected\|401\|'
$processed = [int](@($events | Where-Object { $_ -match '^İşlendi\|' } | ForEach-Object { ($_ -split '\|')[1] }) | Measure-Object -Sum).Sum
Check ($signedOk -gt 0 -and $signedOk401 -eq 0) "doğru imzalı $signedOk haberin hiçbiri 401 almadı ($signedOk401)"
Check ($bad -gt 0 -and $badRejected -eq $bad) "eski zaman damgalı ya da yanlış anahtarlı $bad haberin hepsi 401 ile reddedildi ($badRejected)"
Check ($processed -gt 0) "servis haberleri işliyor: erp_webhook_events'te $processed İşlendi"

Save-Report
Write-Result $allPassed 'Webhook JWT istemiyor; HMAC eskisi gibi: doğru imzalı haberler işleniyor, yalnızca bozuk ya da eski imzalılar 401.'
