# Gün 4 - Adım 2: POST /api/v1/erp-webhooks ve imza doğrulaması. Kontrol listesi 7 + ek durumlar. ~1 dk.
#
#   Kontrol listesi 7 (görev): elle üç istek -> üçü de 401, erp_webhook_events'e hiçbiri yazılmıyor.
#     K1) yanlış imzalı   K2) imza başlıkları yok   K3) 10 dakika önceki zaman damgasıyla, o damgaya göre geçerli imza
#   Ek durumlar (bizim kurallarımız):
#     E1) doğru imzalı, geçerli haber -> 200 ve kaydedilir (FTR-000001'in referansı ERP-TEST değil: Yok Sayıldı)
#     E2) yalnızca X-Erp-Timestamp var, X-Erp-Signature yok -> 401
#     E3) 10 dakika ileri tarihli damga, geçerli imza -> 401
#     E4) zaman damgası sayı değil ("abc") -> 401
#     E5) imzadan sonra gövde değiştirilmiş (approved -> rejected) -> 401
#     E6) doğru imza, geçersiz JSON -> 400
#     E7) doğru imza, red haberi ama reason yok -> 400
#     E8) 70 KB gövde -> 413 (imza hesaplanmadan)
#   Her cevap 5 sn'den kısa; 401 gövdesi nedeni söylemiyor; nedenler yalnızca servis logunda.
#
# Adım 3'ten beri geçerli haber kaydediliyor: tabloda bu script'ten yalnızca E1 olmalı (401/400/413 alanlar yok).
#
# Önce servisin yeni kodla derlenmiş olması gerekir: docker compose up -d --build invoice-service
. "$PSScriptRoot\_common.ps1"

Write-Title 'Adım 2) Haber endpoint''i ve imza doğrulaması (kontrol listesi 7 + ek durumlar)'
Wait-Service
$secret = Get-WebhookSecret
$prefix = New-Prefix 'adim2'
$startedAt = [datetime]::UtcNow.AddSeconds(-2)
$allPassed = $true

$cases = @()
function Add-Case([string]$Id, [string]$Name, [int]$Expected, [string]$LogReason, [scriptblock]$Send) {
    $script:cases += [pscustomobject]@{ Id = $Id; Name = $Name; Expected = $Expected; LogReason = $LogReason; Send = $Send }
}

function Body([string]$Id, [string]$Type = 'invoice.approved', [string]$Reason) {
    [Text.Encoding]::UTF8.GetBytes((New-WebhookBody "$prefix$Id" $Type 'FTR-000001' 'ERP-TEST' $Reason))
}

Add-Case 'K1' 'yanlış imzalı' 401 'bad-signature' {
    $b = Body 'K1'; $ts = "$(Get-UnixNow)"
    Send-Webhook $b $ts (Get-WebhookSignature 'yanlis-anahtar-yanlis-anahtar-yanlis-anahtar' $ts $b) }
Add-Case 'K2' 'imza başlıkları yok' 401 'missing-headers' {
    Send-Webhook (Body 'K2') $null $null }
Add-Case 'K3' '10 dk önceki damga, o damgaya göre geçerli imza' 401 'expired' {
    $b = Body 'K3'; $ts = "$((Get-UnixNow) - 600)"
    Send-Webhook $b $ts (Get-WebhookSignature $secret $ts $b) }
Add-Case 'E1' 'doğru imzalı geçerli haber' 200 '' {
    $b = Body 'E1'; $ts = "$(Get-UnixNow)"
    Send-Webhook $b $ts (Get-WebhookSignature $secret $ts $b) }
Add-Case 'E2' 'yalnızca X-Erp-Timestamp var' 401 'missing-headers' {
    Send-Webhook (Body 'E2') "$(Get-UnixNow)" $null }
Add-Case 'E3' '10 dk ileri tarihli damga, geçerli imza' 401 'from-future' {
    $b = Body 'E3'; $ts = "$((Get-UnixNow) + 600)"
    Send-Webhook $b $ts (Get-WebhookSignature $secret $ts $b) }
Add-Case 'E4' 'zaman damgası "abc"' 401 'bad-timestamp' {
    $b = Body 'E4'
    Send-Webhook $b 'abc' (Get-WebhookSignature $secret 'abc' $b) }
Add-Case 'E5' 'imzadan sonra gövde değiştirilmiş' 401 'bad-signature' {
    $ts = "$(Get-UnixNow)"; $sig = Get-WebhookSignature $secret $ts (Body 'E5' 'invoice.approved')
    Send-Webhook (Body 'E5' 'invoice.rejected' 'sahte') $ts $sig }
Add-Case 'E6' 'doğru imza, geçersiz JSON' 400 'invalid-json' {
    $b = [Text.Encoding]::UTF8.GetBytes('{"event_id": '); $ts = "$(Get-UnixNow)"
    Send-Webhook $b $ts (Get-WebhookSignature $secret $ts $b) }
Add-Case 'E7' 'doğru imza, red haberinde reason yok' 400 'invalid-fields' {
    $b = Body 'E7' 'invoice.rejected'; $ts = "$(Get-UnixNow)"
    Send-Webhook $b $ts (Get-WebhookSignature $secret $ts $b) }
Add-Case 'E8' '70 KB gövde' 413 'too-large' {
    $b = [Text.Encoding]::UTF8.GetBytes('{"x":"' + ('a' * 70000) + '"}'); $ts = "$(Get-UnixNow)"
    Send-Webhook $b $ts (Get-WebhookSignature $secret $ts $b) }

Write-Step "İstekler (event_id öneki: $prefix)"
foreach ($c in $cases) {
    $r = & $c.Send
    $c | Add-Member Status $r.Status
    $c | Add-Member Ms $r.Ms
    $c | Add-Member ResponseBody $r.Body
    $ok = $r.Status -eq $c.Expected -and $r.Ms -lt 5000
    if (-not $ok) { $allPassed = $false }
    Write-Host ('  {0}  {1,-48} -> HTTP {2} (beklenen {3}), {4} ms' -f $c.Id, $c.Name, $r.Status, $c.Expected, $r.Ms) `
        -ForegroundColor ($(if ($ok) { 'Gray' } else { 'Red' }))
}

Write-Step '401 cevabının gövdesi (nedeni söylememeli)'
$k1 = $cases | Where-Object Id -eq 'K1'
Write-Host "  $($k1.ResponseBody)" -ForegroundColor DarkGray
$leaks = @($cases | Where-Object { $_.Status -eq 401 -and $_.ResponseBody -match 'signature|expired|timestamp|header|future' })
$ok = $leaks.Count -eq 0
if (-not $ok) { $allPassed = $false }
Write-DbVerdict '401 gövdelerinde neden yok' "nedeni söyleyen 401 sayısı: $($leaks.Count)" $ok | Out-Null

Write-Step 'Servis logu (nedenler yalnızca burada)'
Start-Sleep -Milliseconds 500
$log = @(Get-WebhookLog $startedAt)
$log | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
foreach ($c in $cases | Where-Object LogReason) {
    $count = @($log | Where-Object { $_ -match "http=$($c.Expected) reason=$([regex]::Escape($c.LogReason))" }).Count
    if ($count -lt 1) { $allPassed = $false; Write-Host "  $($c.Id): logda 'http=$($c.Expected) reason=$($c.LogReason)' yok" -ForegroundColor Red }
}
$stored1 = @($log | Where-Object { $_ -match "ERP webhook stored event=${prefix}E1 " }).Count
if ($stored1 -ne 1) { $allPassed = $false; Write-Host "  E1: logda 'stored' satırı yok" -ForegroundColor Red }

Write-DbHeader 'erp_webhook_events' 'Bu script''in haberlerinden yalnızca E1 tabloda olmalı; 401/400/413 alanlar yazılmamalı'
$sql = "SELECT event_id, status, ignore_reason FROM erp_webhook_events WHERE event_id LIKE '$prefix%' ORDER BY event_id;"
Show-ServiceQuery $sql
$ids = @(Get-ServiceRows "SELECT event_id FROM erp_webhook_events WHERE event_id LIKE '$prefix%' ORDER BY event_id;")
$ok = ($ids -join ',') -eq "${prefix}E1"
if (-not $ok) { $allPassed = $false }
Write-DbVerdict "yalnızca ${prefix}E1 (K1, K2, K3 ve diğer reddedilenler yok)" "$($ids.Count) satır: $($ids -join ', ')" $ok | Out-Null

Write-Result $allPassed 'yanlış imza, eksik başlık, eski/ileri tarihli damga 401 ve kaydedilmedi; bozuk içerik 400; büyük gövde 413'
