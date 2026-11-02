# Kapatılan bulguların önce/sonra kontrolü: her bölüm bir bulgunun istismar isteğini gönderir. TAMAM = beklenen güvenli
# durum, FARKLI = bulgu sürüyor. Düzeltmelerden önce ve sonra aynı script koşulur; çıktı
# manual-tests\output\gun21\<-Etiket>.txt. Kalıcı iz bırakmaz: kilit denemesi geçici bir kullanıcıyla yapılır ve kullanıcı
# silinir, DROP TABLE ROLLBACK ile geri alınır, alarm susturma kaydı hemen silinir. ~3 dk.
#   .\manual-tests\gun21\1-once-sonra.ps1 -Etiket b-once
param([string]$Etiket = 'b-once-sonra')
. "$PSScriptRoot\_common.ps1"

New-Report $Etiket
Write-Title 'Kapatılan bulgular: önce/sonra'
Start-Stack
Write-Line "Koşu: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
$form = 'application/x-www-form-urlencoded'
function Get-Field([string]$Body, [string]$Name) { try { ($Body | ConvertFrom-Json).$Name } catch { $null } }

Write-Line ''
Write-Line 'O2) Grafana yönetici girişi'
$gfDefault = Send-Http POST 'http://localhost:3000/login' @{} '{"user":"admin","password":"admin"}'
Check ($gfDefault.Status -ne 200) "POST /login admin/admin (imajın varsayılanı): HTTP $($gfDefault.Status)"
$gfPassword = try { Get-DotEnvValue 'GRAFANA_ADMIN_PASSWORD' } catch { $null }
if ($gfPassword) {
    $gfEnv = Send-Http POST 'http://localhost:3000/login' @{} (@{ user = 'admin'; password = $gfPassword } | ConvertTo-Json)
    Check ($gfEnv.Status -eq 200) "POST /login admin ve .env'deki GRAFANA_ADMIN_PASSWORD: HTTP $($gfEnv.Status)"
}
else { Write-Line "  .env'de GRAFANA_ADMIN_PASSWORD yok" }

Write-Line ''
Write-Line 'O1) Kaba kuvvet koruması ve şifre politikası (geçici kullanıcı gun21-deneme, fatura-test client''ı)'
& "$PSScriptRoot\..\keycloak\test-client-ekle.ps1" -KeycloakUrl $KeycloakUrl | Out-Null
$realm = Get-Admin ''
Write-Line "  Realm: bruteForceProtected=$($realm.bruteForceProtected), failureFactor=$($realm.failureFactor), waitIncrementSeconds=$($realm.waitIncrementSeconds), maxFailureWaitSeconds=$($realm.maxFailureWaitSeconds), passwordPolicy='$($realm.passwordPolicy)'"
# Geçici kullanıcı yönetim API'siyle açılır: Keycloak'ta sonradan açılan her kullanıcı gibi realm'in varsayılan rollerini
# alır (realm dosyasıyla içe aktarılan test kullanıcıları yalnız dosyada yazan rolleri alır). Varsa önce silinir.
function New-TempUser([string]$Name) {
    foreach ($u in @(Get-Admin "/users?username=$Name&exact=true")) { if ($u.id) { [void](Send-Admin DELETE "/users/$($u.id)") } }
    $password = -join ((1..32) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
    $created = Send-Admin POST '/users' (@{ username = $Name; enabled = $true; email = "$Name@fatura.test"; emailVerified = $true
        firstName = 'Gun21'; lastName = 'Deneme'; credentials = @(@{ type = 'password'; value = $password; temporary = $false }) } | ConvertTo-Json -Depth 4)
    Write-Line "  Geçici kullanıcı $Name oluşturuldu: HTTP $($created.Status)"
    [pscustomobject]@{ Id = (Get-Admin "/users?username=$Name&exact=true")[0].id; Password = $password }
}
$temp = New-TempUser 'gun21-deneme'
$userId = $temp.Id; $userPassword = $temp.Password
$login = { param($Password) Send-Http POST $TokenUrl @{} "grant_type=password&client_id=fatura-test&username=gun21-deneme&password=$Password" $form }
# Denemeler arasında 1,5 sn: Keycloak'ın 1 sn içindeki art arda denemeler için ayrı kuralı (quickLoginCheckMilliSeconds)
# değil, art arda yanlış şifre sayısı (failureFactor) ölçülsün.
$wrong = foreach ($i in 1..5) { (& $login 'yanlis-sifre').Status; Start-Sleep -Milliseconds 1500 }
Write-Line "  5 yanlış şifre (1,5 sn arayla): HTTP $($wrong -join ', ')"
$afterWrong = & $login $userPassword
Check ($afterWrong.Status -ne 200) "Hemen ardından doğru şifre: HTTP $($afterWrong.Status) $(Get-Field $afterWrong.Body 'error')"
$state = Get-Admin "/attack-detection/brute-force/users/$userId"
Check ($state.disabled -eq $true) "Yönetim API'si attack-detection: disabled=$($state.disabled), numFailures=$($state.numFailures)"
if ($state.disabled -eq $true) {
    Write-Line '  Kilit süresinin bitmesi için 65 sn bekleniyor'
    Start-Sleep -Seconds 65
    $later = & $login $userPassword
    Check ($later.Status -eq 200) "65 sn sonra doğru şifre: HTTP $($later.Status) (kilit geçici)"
}
$short = Send-Admin PUT "/users/$userId/reset-password" '{"type":"password","value":"kisa1","temporary":false}'
Check ($short.Status -eq 400) "Şifreyi 'kisa1' yapma (yönetim API'si): HTTP $($short.Status) $(Get-Field $short.Body 'error_description')$(Get-Field $short.Body 'errorMessage')"
[void](Send-Admin DELETE "/users/$userId")

Write-Line ''
Write-Line 'O7) operasyon-ekrani client''ı: offline token ve refresh token''ın ikinci kullanımı (Authorization Code + PKCE)'
$ekranUser = New-TempUser 'gun21-ekran'
$roles = @(Get-Admin "/users/$($ekranUser.Id)/role-mappings/realm/composite" | ForEach-Object { $_.name })
Write-Line "  gun21-ekran'ın realm rolleri (varsayılan rollerden): $(($roles | Sort-Object) -join ', ')"
# Ekranın giriş akışı (Authorization Code + PKCE): giriş formu kullanıcı adı ve şifreyle gönderilir, dönen kod token'la
# değiştirilir. Keycloak'ın oturum çerezleri elle taşınır: Windows PowerShell'in CookieContainer'ı bu çerezleri
# (Version=1, SameSite) kaydetmiyor.
function Get-EkranTokens([string]$Scope, [pscustomobject]$User, [string]$UserName) {
    $browser = [Net.Http.HttpClient]::new([Net.Http.HttpClientHandler]@{ AllowAutoRedirect = $false; UseCookies = $false })
    $verifier = -join ((1..64) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
    $challenge = [Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $redirect = [Uri]::EscapeDataString('http://localhost:5100/')
    $authUrl = "$KeycloakUrl/realms/fatura/protocol/openid-connect/auth?client_id=operasyon-ekrani&response_type=code" +
        "&scope=$([Uri]::EscapeDataString($Scope))&redirect_uri=$redirect&state=gun21&code_challenge=$challenge&code_challenge_method=S256"
    $loginPage = $browser.GetAsync($authUrl).GetAwaiter().GetResult()
    # Keycloak isteği giriş formunu göstermeden reddederse hatayla geri yönlendirir (ör. error=invalid_scope).
    $authError = [regex]::Match("$($loginPage.Headers.Location)", '[?&]error=([^&]+)&error_description=([^&]+)')
    if ($authError.Success) {
        Write-Line "  Giriş, scope '$Scope': Keycloak reddetti, $($authError.Groups[1].Value): $([Uri]::UnescapeDataString($authError.Groups[2].Value.Replace('+', ' ')))"
        return [pscustomobject]@{ Status = 'reddedildi'; Refresh = $null; Type = $null }
    }
    $page = $loginPage.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $cookies = ($loginPage.Headers.GetValues('Set-Cookie') | ForEach-Object { $_.Split(';')[0] }) -join '; '
    $action = [Net.WebUtility]::HtmlDecode([regex]::Match($page, 'id="kc-form-login"[^>]*action="([^"]+)"').Groups[1].Value)
    $loginPost = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $action)
    $loginPost.Content = [Net.Http.StringContent]::new("username=$UserName&password=$($User.Password)&credentialId=", [Text.Encoding]::UTF8, $form)
    [void]$loginPost.Headers.TryAddWithoutValidation('Cookie', $cookies)
    $posted = $browser.SendAsync($loginPost).GetAwaiter().GetResult()
    $code = [regex]::Match("$($posted.Headers.Location)", '[?&]code=([^&]+)').Groups[1].Value
    $tokens = Send-Http POST $TokenUrl @{} "grant_type=authorization_code&client_id=operasyon-ekrani&code=$code&redirect_uri=$redirect&code_verifier=$verifier" $form
    $json = if ($tokens.Status -eq 200) { $tokens.Body | ConvertFrom-Json } else { $null }
    Write-Line "  Giriş, scope '$Scope': HTTP $($tokens.Status), verilen scope '$($json.scope)' $(Get-Field $tokens.Body 'error_description')"
    [pscustomobject]@{ Status = $tokens.Status; Refresh = $json.refresh_token; Type = $(if ($json) { (Get-TokenClaims $json.refresh_token).typ }) }
}
$refresh = { param($Token) Send-Http POST $TokenUrl @{} "grant_type=refresh_token&client_id=operasyon-ekrani&refresh_token=$Token" $form }

$offline = Get-EkranTokens 'openid offline_access' $ekranUser 'gun21-ekran'
# Offline token verilmemesi iki yoldan olabilir: scope yok sayılır (200, normal refresh token) ya da Keycloak isteği
# reddeder (nedeni satırda yazar).
Check ($offline.Status -in 200, 'reddedildi' -and $offline.Type -ne 'Offline') "    offline_access istenince refresh token'ın türü (typ): $($offline.Type)"
$normal = Get-EkranTokens 'openid' $ekranUser 'gun21-ekran'
Write-Line "    refresh token'ın türü (typ): $($normal.Type)"
$first = & $refresh $normal.Refresh
$second = & $refresh $normal.Refresh
Write-Line "  Refresh token 1. kullanım: HTTP $($first.Status)"
Check ($first.Status -eq 200 -and $second.Status -eq 400) "Aynı refresh token 2. kullanım: HTTP $($second.Status) $(Get-Field $second.Body 'error') $(Get-Field $second.Body 'error_description')"
if ($first.Status -eq 200) {
    $third = & $refresh ($first.Body | ConvertFrom-Json).refresh_token
    Write-Line "  1. kullanımda verilen yeni refresh token, reddedilen 2. kullanımdan sonra: HTTP $($third.Status) $(Get-Field $third.Body 'error_description')"
}
[void](Send-Admin DELETE "/users/$($ekranUser.Id)")

Write-Line ''
Write-Line 'O4) Operasyon ekranının HTTP başlıkları (nginx)'
$index = Send-Http GET 'http://localhost:5100/'
$asset = [regex]::Match($index.Body, '/assets/[^"]+\.js').Value
$responses = [ordered]@{ '/' = $index; $asset = (Send-Http GET "http://localhost:5100$asset"); '/assets/yok.js (404)' = (Send-Http GET 'http://localhost:5100/assets/yok.js') }
foreach ($path in $responses.Keys) {
    $h = $responses[$path].Headers
    Write-Line "  GET $path → HTTP $($responses[$path].Status)"
    Check ($h['content-security-policy'] -match "frame-ancestors 'none'") "    Content-Security-Policy: $($h['content-security-policy'])"
    Check ($h['x-content-type-options'] -eq 'nosniff') "    X-Content-Type-Options: $($h['x-content-type-options'])"
    Check ([bool]$h['referrer-policy']) "    Referrer-Policy: $($h['referrer-policy'])"
    Check ($h['server'] -notmatch '\d') "    Server: $($h['server'])"
}

Write-Line ''
Write-Line 'O9) Uygulamaların veritabanı kullanıcısı (uygulamanın kendi bağlantı dizesindeki kullanıcı ve şifreyle)'
foreach ($app in @(@{ Service = 'invoice-service'; Variable = 'ConnectionStrings__InvoiceDb'; Db = 'invoice-db'; Name = 'invoice_service'; Table = 'invoices'; Other = 'erp-db'; OtherName = 'erp_simulator' },
                   @{ Service = 'erp-simulator'; Variable = 'ConnectionStrings__ErpDb'; Db = 'erp-db'; Name = 'erp_simulator'; Table = 'invoices'; Other = 'invoice-db'; OtherName = 'invoice_service' })) {
    $cred = Get-AppDbUser $app.Service $app.Variable
    Write-Line "  $($app.Service): kullanıcı $($cred.User)"
    $role = Invoke-Psql $app.Db $cred.User $cred.Password $app.Name 'SELECT rolsuper FROM pg_roles WHERE rolname = current_user'
    Check ($role.Text -eq 'f') "    süper kullanıcı mı (rolsuper): $($role.Text)"
    # CASCADE: tabloya bağlı yabancı anahtarlar silmeyi yetkiden önce durdurmasın; ROLLBACK her durumda geri alır.
    $drop = Invoke-Psql $app.Db $cred.User $cred.Password $app.Name "BEGIN; DROP TABLE $($app.Table) CASCADE; ROLLBACK;"
    Check (-not $drop.Ok) "    BEGIN; DROP TABLE $($app.Table) CASCADE; ROLLBACK: $(if ($drop.Ok) { 'silindi (ROLLBACK ile geri alındı)' } else { $drop.Text })"
    $postgres = Invoke-Psql $app.Db $cred.User $cred.Password 'postgres' 'SELECT current_database()'
    Check (-not $postgres.Ok) "    aynı sunucuda postgres veritabanına bağlantı: $(if ($postgres.Ok) { 'bağlandı' } else { $postgres.Text })"
    $other = Invoke-Psql $app.Other $cred.User $cred.Password $app.OtherName 'SELECT current_database()'
    Check (-not $other.Ok) "    $($app.Other)/$($app.OtherName) bağlantısı: $(if ($other.Ok) { 'bağlandı' } else { $other.Text })"
}

Write-Line ''
Write-Line 'O3, O10) Prometheus, Alertmanager, Jaeger: kimliksiz istek, token''la istek ve başka origin''den istek'
$operator = Get-UserToken 'operator'
$izleyici = Get-UserToken 'izleyici'
$tools = [ordered]@{
    'Prometheus GET /api/v1/query?query=up' = 'http://localhost:9090/api/v1/query?query=up'
    'Alertmanager GET /api/v2/alerts'       = 'http://localhost:9093/api/v2/alerts'
    'Jaeger GET /api/services'              = 'http://localhost:16686/api/services'
}
foreach ($name in $tools.Keys) {
    $anon = Send-Http GET $tools[$name]
    Check ($anon.Status -ne 200) "$name, token'sız: HTTP $($anon.Status)"
    $op = Send-Http GET $tools[$name] @{ Authorization = "Bearer $operator" }
    Write-Line "    operator token'ıyla: HTTP $($op.Status)"
    $iz = Send-Http GET $tools[$name] @{ Authorization = "Bearer $izleyici" }
    Write-Line "    izleyici token'ıyla: HTTP $($iz.Status)"
}
$silenceBody = @{ matchers = @(@{ name = 'alertname'; value = 'Gun21Deneme'; isRegex = $false; isEqual = $true }); startsAt = (Get-Date).ToUniversalTime().ToString('o')
    endsAt = (Get-Date).AddMinutes(1).ToUniversalTime().ToString('o'); createdBy = 'gun21'; comment = 'önce/sonra denemesi' } | ConvertTo-Json -Depth 4
$silence = Send-Http POST 'http://localhost:9093/api/v2/silences' @{} $silenceBody
Check ($silence.Status -ne 200) "Alertmanager POST /api/v2/silences (alarm susturma), token'sız: HTTP $($silence.Status)"
$silenceId = Get-Field $silence.Body 'silenceID'
if ($silenceId) { [void](Send-Http DELETE "http://localhost:9093/api/v2/silence/$silenceId") }
$grafanaProxy = Send-Http GET 'http://localhost:3000/api/datasources/proxy/uid/prometheus/api/v1/query?query=up'
Check ($grafanaProxy.Status -ne 200) "Grafana üzerinden Prometheus sorgusu (veri kaynağı proxy'si), girişsiz: HTTP $($grafanaProxy.Status)"
$origin = @{ Origin = 'http://kotu-site.example' }
$corsProm = Send-Http GET 'http://localhost:9090/api/v1/query?query=up' $origin
Check (-not $corsProm.Headers['access-control-allow-origin']) "Prometheus, Origin: http://kotu-site.example, token'sız: HTTP $($corsProm.Status), Access-Control-Allow-Origin: $($corsProm.Headers['access-control-allow-origin'])"
$corsAm = Send-Http OPTIONS 'http://localhost:9093/api/v2/silences' ($origin + @{ 'Access-Control-Request-Method' = 'POST'; 'Access-Control-Request-Headers' = 'content-type' })
Check (-not $corsAm.Headers['access-control-allow-origin']) "Alertmanager preflight (POST silences), token'sız: HTTP $($corsAm.Status), Access-Control-Allow-Origin: $($corsAm.Headers['access-control-allow-origin'])"
$corsPromAuth = Send-Http GET 'http://localhost:9090/api/v1/query?query=up' ($origin + @{ Authorization = "Bearer $operator" })
Check (-not $corsPromAuth.Headers['access-control-allow-origin']) "Prometheus, Origin: http://kotu-site.example, operator token'ıyla: HTTP $($corsPromAuth.Status), Access-Control-Allow-Origin: $($corsPromAuth.Headers['access-control-allow-origin'])"
$corsAmAuth = Send-Http GET 'http://localhost:9093/api/v2/alerts' ($origin + @{ Authorization = "Bearer $operator" })
Check (-not $corsAmAuth.Headers['access-control-allow-origin']) "Alertmanager, Origin: http://kotu-site.example, operator token'ıyla: HTTP $($corsAmAuth.Status), Access-Control-Allow-Origin: $($corsAmAuth.Headers['access-control-allow-origin'])"

Write-Line ''
Write-Line "Sonuç: $(if ($script:AllPassed) { 'bütün kontroller TAMAM' } else { 'FARKLI satırlar var' })"
Save-Report
