# Güvenlik gözden geçirmesinin canlı kontrolleri: compose yığınına bir saldırganın göreceği yerden bakar. Her satır bir
# gözlemdir (TAMAM = beklenen güvenli durum, FARKLI = bulgu). Düzeltmelerden önce ve sonra aynı script koşulur; çıktı
# manual-tests\output\gun20\<-Etiket>.txt. ~2 dk.
#   .\manual-tests\gun20\1-canli-tarama.ps1 -Etiket b-canli-once
param([string]$Etiket = 'b-canli-tarama')
. "$PSScriptRoot\_common.ps1"

New-Report $Etiket
Write-Title 'Güvenlik gözden geçirmesi: canlı kontroller'
Push-Location $RepoRoot
try { docker compose up -d --build 2>&1 | Out-Null } finally { Pop-Location }
Wait-KeycloakAndService
$lan = Get-LanAddress
Write-Line "Yerel ağ adresi: $lan  ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"

Write-Line ''
Write-Line 'A) Yayımlanan portlar: yerel ağ adresinden açık mı (açıksa aynı ağdaki her makine bağlanabilir)'
$ports = [ordered]@{ '5433' = 'erp-db (PostgreSQL)'; '5434' = 'invoice-db (PostgreSQL)'; '5080' = 'erp-simulator'; '5090' = 'invoice-service'
    '5100' = 'operations-ui'; '8080' = 'keycloak'; '16686' = 'jaeger'; '9090' = 'prometheus'; '9093' = 'alertmanager'; '3000' = 'grafana' }
foreach ($p in $ports.Keys) {
    $open = Test-Port $lan ([int]$p)
    Check (-not $open) ("{0,-5} {1,-24} yerel ağdan {2}" -f $p, $ports[$p], $(if ($open) { 'AÇIK' } else { 'kapalı' }))
}

Write-Line ''
Write-Line 'B) Repodaki şifrelerle yerel ağ adresinden giriş'
$psql = @(docker compose exec -T invoice-db psql "postgresql://invoice:invoice@${lan}:5434/invoice_service" -tAc 'SELECT current_user || '' kullanıcısıyla, invoices tablosunda '' || (SELECT count(*) FROM invoices) || '' satır'';' 2>&1)
$dbOpen = $LASTEXITCODE -eq 0
Check (-not $dbOpen) "invoice-db, invoice/invoice: $(if ($dbOpen) { "giriş yapıldı: $($psql[-1])" } else { "giriş yok ($($psql[-1]))" })"
$kc = Send-Http POST "http://${lan}:8080/realms/master/protocol/openid-connect/token" @{} 'grant_type=password&client_id=admin-cli&username=admin&password=admin' 'application/x-www-form-urlencoded'
Check ($kc.Status -ne 200) "Keycloak master realm, admin/admin: HTTP $($kc.Status)$(if ($kc.Status -eq 200) { ' (yönetici token''ı alındı: kullanıcı/rol/anahtar değiştirilebilir)' })"
$gf = Send-Http GET "http://${lan}:3000/api/admin/settings" @{ Authorization = (Get-BasicAuth 'admin' 'admin') }
Check ($gf.Status -ne 200) "Grafana, admin/admin ile yönetici API'si: HTTP $($gf.Status)"
$op = Send-Http POST "http://${lan}:8080/realms/fatura/protocol/openid-connect/token" @{} 'grant_type=client_credentials&client_id=siparis-sistemi&client_secret=dev-only-siparis-sistemi-secret-do-not-use-in-production' 'application/x-www-form-urlencoded'
Check ($op.Status -ne 200) "Sipariş sistemi client secret'ı (realm dosyasındaki): HTTP $($op.Status)$(if ($op.Status -eq 200) { ' (fatura oluşturma yetkili token)' })"

Write-Line ''
Write-Line 'B2) Repoda duran ya da daha önce duran değerlerle bu bilgisayardan giriş: port kapalı olsa da değerin kendisi işe yarıyor mu'
# Veritabanına compose ağındaki adıyla bağlanılır: 127.0.0.1'den gelen bağlantıya PostgreSQL imajı şifre sormaz.
foreach ($db in @(@{ Service = 'invoice-db'; Url = 'postgresql://invoice:invoice@invoice-db:5432/invoice_service' },
                  @{ Service = 'erp-db'; Url = 'postgresql://erp:erp@erp-db:5432/erp_simulator' })) {
    $psqlLocal = @(docker compose exec -T $db.Service psql $db.Url -tAc 'SELECT current_user;' 2>&1)
    $dbLocal = $LASTEXITCODE -eq 0
    # Ret yalnız "şifre yanlış" ise sayılır; başka bir hata (container yok gibi) kontrolü geçmiş saymaz.
    $wrongPassword = "$($psqlLocal[-1])" -match 'password authentication failed'
    Check ((-not $dbLocal) -and $wrongPassword) "$($db.Service), repodaki eski şifre: $(if ($dbLocal) { 'giriş yapıldı' } else { "giriş yok ($($psqlLocal[-1]))" })"
}
# Keycloak'ın reddi nedeniyle birlikte yazılır; yalnız kimlik bilgisinin yanlış olduğunu söyleyen cevap TAMAM sayılır.
function Test-KeycloakLogin([string]$Realm, [string]$Form, [string]$Text) {
    $r = Send-Http POST "http://localhost:8080/realms/$Realm/protocol/openid-connect/token" @{} $Form 'application/x-www-form-urlencoded'
    $kcError = if ($r.Body -match '"error"\s*:\s*"([^"]+)"') { $Matches[1] } else { '-' }
    Check ($r.Status -in 400, 401 -and $kcError -in 'invalid_grant', 'unauthorized_client', 'invalid_client') "$Text`: HTTP $($r.Status) error=$kcError"
}
Test-KeycloakLogin 'master' 'grant_type=password&client_id=admin-cli&username=admin&password=admin' 'Keycloak master realm, admin/admin'
Test-KeycloakLogin 'fatura' 'grant_type=client_credentials&client_id=siparis-sistemi&client_secret=dev-only-siparis-sistemi-secret-do-not-use-in-production' "Sipariş sistemi, repodaki eski client secret'ı"
# Test kullanıcılarının repodaki eski şifreleri; şifreyle token veren test client'ı gerekir (yoksa eklenir).
& "$PSScriptRoot\..\keycloak\test-client-ekle.ps1" -KeycloakUrl $KeycloakUrl | Out-Null
foreach ($user in 'izleyici', 'operator', 'rolsuz') {
    Test-KeycloakLogin 'fatura' "grant_type=password&client_id=fatura-test&username=$user&password=${user}123" "Test kullanıcısı $user, repodaki eski şifre"
}

Write-Line ''
Write-Line 'C) Kimlik doğrulaması olmayan yönetim/izleme uçları (yerel ağ adresinden)'
$from = [Uri]::EscapeDataString((Get-Date).ToUniversalTime().AddDays(-30).ToString('yyyy-MM-ddTHH:mm:ssZ'))
$to = [Uri]::EscapeDataString((Get-Date).ToUniversalTime().AddDays(1).ToString('yyyy-MM-ddTHH:mm:ssZ'))
$erp = Send-Http GET "http://${lan}:5080/api/v1/invoices?from=$from&to=$to&pageSize=1"
Check ($erp.Status -ne 200) "ERP Simülatörü fatura listesi, token'sız: HTTP $($erp.Status)"
$silence = '{"matchers":[{"name":"alertname","value":"gun20-tarama-deneme","isRegex":false}],"startsAt":"' +
    (Get-Date).ToUniversalTime().ToString('o') + '","endsAt":"' + (Get-Date).ToUniversalTime().AddMinutes(1).ToString('o') +
    '","createdBy":"gun20-tarama","comment":"kimliksiz yazma denemesi; hemen silinir"}'
$am = Send-Http POST "http://${lan}:9093/api/v2/silences" @{} $silence
Check ($am.Status -ne 200) "Alertmanager'a token'sız susturma (silence) yazma: HTTP $($am.Status)"
if ($am.Status -eq 200) { [void](Send-Http DELETE "http://${lan}:9093/api/v2/silence/$(($am.Body | ConvertFrom-Json).silenceID)") }
$prom = Send-Http GET "http://${lan}:9090/api/v1/status/config"
Check ($prom.Status -ne 200) "Prometheus ayarları token'sız: HTTP $($prom.Status)"
$jg = Send-Http GET "http://${lan}:16686/api/services"
Check ($jg.Status -ne 200) "Jaeger izleri token'sız: HTTP $($jg.Status)"

Write-Line ''
Write-Line 'D) Repodaki webhook secret''ıyla sahte ERP haberi: gerçek bir faturayı reddedilmiş gösterme'
$created = Send-Api POST '/api/v1/invoices' (Get-OrderSystemToken) '{"customerCode":"GUN20-SAHTE-HABER","amount":10.5,"currency":"TRY","invoiceDate":"2026-10-27"}'
$numbers = @($created.Json.invoiceNumber)
[void](Wait-InvoicesIn $numbers @('Gönderildi', 'Onaylandı', 'Reddedildi', 'Başarısız') 120 'ERP''ye gönderilmiş')
$before = @(Get-ServiceRows "SELECT status || '|' || coalesce(erp_reference, '-') FROM invoices WHERE invoice_number = '$($numbers[0])';")[0]
$lookup = Send-Http GET "http://localhost:5080/api/v1/invoices/$($numbers[0])"
$reference = if ($lookup.Status -eq 200) { ($lookup.Body | ConvertFrom-Json).erpReference } else { '' }
Write-Line "  Fatura $($numbers[0]): servisteki durum|referans = $before; ERP referansı token'sız okundu: '$reference'"
# Saldırganın bildiği, repoda duran değer (servislerin kullandığı .env'deki değer değil).
$secret = 'dev-only-erp-webhook-secret-do-not-use-in-production'
$body = [Text.Encoding]::UTF8.GetBytes((New-WebhookBody "gun20-sahte-$(Get-Date -Format 'HHmmss')" 'invoice.rejected' $numbers[0] $reference 'gun20 sahte ret'))
$ts = [string](Get-UnixNow)
$forged = Send-Webhook $body $ts (Get-WebhookSignature $secret $ts $body)
$after = @(Get-ServiceRows "SELECT status FROM invoices WHERE invoice_number = '$($numbers[0])';")[0]
Check ($forged.Status -eq 401) "repodaki secret'la imzalanmış sahte ret haberi: HTTP $($forged.Status); faturanın durumu $($before.Split('|')[0]) -> $after"

Write-Line ''
Write-Line 'E) Operasyon ekranının HTTP güvenlik başlıkları (GET http://localhost:5100/)'
$ui = Send-Http GET 'http://localhost:5100/'
foreach ($h in 'content-security-policy', 'x-frame-options', 'x-content-type-options', 'referrer-policy', 'permissions-policy', 'strict-transport-security') {
    Check ($ui.Headers.ContainsKey($h)) ("{0,-26} {1}" -f $h, $(if ($ui.Headers.ContainsKey($h)) { $ui.Headers[$h] } else { 'yok' }))
}
Write-Line "  server: $($ui.Headers['server'])"
$api = Send-Http GET 'http://localhost:5090/health'
Write-Line "  Fatura Servisi /health başlıkları: $((($api.Headers.Keys | Sort-Object) -join ', '))"

Write-Line ''
Write-Line 'F) CORS (Fatura Servisi, preflight)'
$evil = Get-PreflightAllowOrigin '/api/v1/invoices/resend' 'http://kotu-site.example' 'POST'
Check ($evil -eq '') "başka bir site (http://kotu-site.example): Access-Control-Allow-Origin = '$evil'"
$good = Get-PreflightAllowOrigin '/api/v1/invoices/resend' 'http://localhost:5100' 'POST'
Check ($good -eq 'http://localhost:5100') "operasyon ekranı (http://localhost:5100): Access-Control-Allow-Origin = '$good'"
Check ((Get-PreflightAllowOrigin '/api/v1/invoices/resend' 'null' 'POST') -eq '') "Origin: null (sandbox iframe, dosya): izin yok"

Write-Line ''
Write-Line 'G) Kimliksiz açık kalan uçlar ve hata cevapları (Fatura Servisi)'
foreach ($path in '/health', '/swagger/index.html', '/openapi/v1.json', '/api/v1/invoices/summary') {
    $r = Send-Http GET "http://localhost:5090$path"
    Write-Line ("  GET {0,-28} token'sız: HTTP {1}" -f $path, $r.Status)
}
$order = Get-OrderSystemToken
$bad = Send-Http POST 'http://localhost:5090/api/v1/invoices' @{ Authorization = "Bearer $order" } '{"customerCode": '
$leak = $bad.Body -match '   at |Exception|StackTrace|Npgsql|InvoiceService\.'
Check (-not $leak) "bozuk JSON gövdesi: HTTP $($bad.Status), cevapta yığın izi/iç ad $(if ($leak) { 'VAR' } else { 'yok' }): $($bad.Body.Substring(0, [Math]::Min(160, $bad.Body.Length)))"
$huge = Send-Http GET ('http://localhost:5090/api/v1/invoices/' + ('9' * 5000)) @{ Authorization = "Bearer $(Get-UserToken 'izleyici')" }
$leak = $huge.Body -match '   at |Exception|StackTrace|Npgsql'
Check (-not $leak) "5000 karakterlik fatura numarası: HTTP $($huge.Status), cevapta iç ayrıntı $(if ($leak) { 'VAR' } else { 'yok' })"
$erpBad = Send-Http POST 'http://localhost:5080/api/v1/invoices' @{} '{"invoiceNumber": '
$leak = $erpBad.Body -match '   at |Exception|StackTrace|Npgsql'
# Cevap gelmediyse (HTTP 0) kontrol yapılmamış sayılır.
Check ($erpBad.Status -ne 0 -and -not $leak) "ERP Simülatörü bozuk JSON: HTTP $($erpBad.Status), cevapta iç ayrıntı $(if ($erpBad.Status -eq 0) { 'kontrol edilemedi (cevap yok)' } elseif ($leak) { 'VAR' } else { 'yok' })"

Write-Line ''
Write-Line 'H) Keycloak realm ayarları (fatura)'
$realm = Get-Admin ''
Check ([bool]$realm.bruteForceProtected) "Kaba kuvvet koruması (bruteForceProtected): $($realm.bruteForceProtected)"
Write-Line "  sslRequired: $($realm.sslRequired); accessTokenLifespan: $($realm.accessTokenLifespan) sn; ssoSessionIdleTimeout: $($realm.ssoSessionIdleTimeout) sn"
Write-Line "  passwordPolicy: '$($realm.passwordPolicy)'"

Save-Report
Write-Result $script:AllPassed 'Canlı kontrollerin hepsi beklenen güvenli durumda.'
