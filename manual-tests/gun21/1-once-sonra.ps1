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
$refresh = { param($Token) Send-Http POST $TokenUrl @{} "grant_type=refresh_token&client_id=operasyon-ekrani&refresh_token=$Token" $form }

$ekran = @{ ClientId = 'operasyon-ekrani'; Redirect = 'http://localhost:5100/'; UserName = 'gun21-ekran'; Password = $ekranUser.Password }
$offline = Get-AuthCodeTokens @ekran -Scope 'openid offline_access'
# Offline token verilmemesi iki yoldan olabilir: scope yok sayılır (200, normal refresh token) ya da Keycloak isteği
# reddeder (nedeni satırda yazar).
Check ($offline.Status -in 200, 'reddedildi' -and $offline.Type -ne 'Offline') "    offline_access istenince refresh token'ın türü (typ): $($offline.Type)"
$normal = Get-AuthCodeTokens @ekran -Scope 'openid'
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
    Check ([bool]$h['permissions-policy']) "    Permissions-Policy: $($h['permissions-policy'])"
    Check ($h['server'] -notmatch '\d') "    Server: $($h['server'])"
}

Write-Line ''
Write-Line 'O9) Uygulamaların veritabanı kullanıcısı (uygulamanın kendi bağlantı dizesindeki kullanıcı ve şifreyle)'
foreach ($app in @(@{ Service = 'invoice-service'; Variable = 'ConnectionStrings__InvoiceDb'; Db = 'invoice-db'; Name = 'invoice_service'; Table = 'invoices'; Other = 'erp-db'; OtherName = 'erp_simulator'
                      AppendOnly = @('operator_actions', 'reconciliation_findings'); AppendOnlyColumn = @{ operator_actions = 'result'; reconciliation_findings = 'details' } },
                   @{ Service = 'erp-simulator'; Variable = 'ConnectionStrings__ErpDb'; Db = 'erp-db'; Name = 'erp_simulator'; Table = 'invoices'; Other = 'invoice-db'; OtherName = 'invoice_service'
                      AppendOnly = @('invoices'); AppendOnlyColumn = @{ invoices = 'amount' } })) {
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
    # Kullanıcı diğer sunucuda hiç yok (önce de yoktu): düzeltmeyi göstermez, yalnız durumu yazar.
    Write-Line "    $($app.Other)/$($app.OtherName) bağlantısı: $(if ($other.Ok) { 'bağlandı' } else { $other.Text })"
    $privileges = Invoke-Psql $app.Db $cred.User $cred.Password $app.Name ("SELECT string_agg(tablename || '=' || " +
        "CASE WHEN has_table_privilege(current_user, quote_ident(tablename), 'UPDATE') THEN 'UPDATE' ELSE '-' END, ', ' ORDER BY tablename) " +
        "FROM pg_tables WHERE schemaname = 'public'")
    Write-Line "    tablolarda UPDATE yetkisi: $($privileges.Text)"
    foreach ($table in $app.AppendOnly) {
        $update = Invoke-Psql $app.Db $cred.User $cred.Password $app.Name "BEGIN; UPDATE $table SET $($app.AppendOnlyColumn[$table]) = $($app.AppendOnlyColumn[$table]) WHERE false; ROLLBACK;"
        Check (-not $update.Ok) "    yalnız eklenen $table tablosunda UPDATE: $(if ($update.Ok) { 'yapılabildi' } else { $update.Text })"
    }
}

Write-Line ''
Write-Line 'O3, O10) Prometheus, Alertmanager, Jaeger: kimliksiz istek, token''la istek ve başka origin''den istek'
# Giriş kapısının kendi client'ından (izleme-girisi) alınan token'lar; fatura-servisi audience'lı API token'ı geçmemeli.
$izleme = @{ ClientId = 'izleme-girisi'; Redirect = 'http://localhost:9090/oauth2/callback'; Scope = 'openid'; ClientSecret = (Get-DotEnvValue 'MONITORING_CLIENT_SECRET') }
$operator = (Get-AuthCodeTokens @izleme -UserName 'operator' -Password $TestUsers['operator']).Access
$izleyici = (Get-AuthCodeTokens @izleme -UserName 'izleyici' -Password $TestUsers['izleyici']).Access
$apiToken = Get-UserToken 'operator'
$tools = [ordered]@{
    'Prometheus GET /api/v1/query?query=up' = 'http://localhost:9090/api/v1/query?query=up'
    'Alertmanager GET /api/v2/alerts'       = 'http://localhost:9093/api/v2/alerts'
    'Jaeger GET /api/services'              = 'http://localhost:16686/api/services'
}
foreach ($name in $tools.Keys) {
    $anon = Send-Http GET $tools[$name]
    # Giriş kapısı oturumu ya da geçerli token'ı olmayan isteği Keycloak girişine yönlendirir (302); başka bir sonuç
    # (bağlantı yok, 5xx) güvenli durumu göstermez.
    Check ($anon.Status -eq 302) "$name, token'sız: HTTP $($anon.Status)"
    $op = Send-Http GET $tools[$name] @{ Authorization = "Bearer $operator" }
    Check ($op.Status -eq 200) "    operator'ün izleme-girisi token'ıyla: HTTP $($op.Status)"
    $iz = Send-Http GET $tools[$name] @{ Authorization = "Bearer $izleyici" }
    Check ($iz.Status -eq 302) "    izleyicinin izleme-girisi token'ıyla (fatura-operatoru rolü yok): HTTP $($iz.Status)"
    $api = Send-Http GET $tools[$name] @{ Authorization = "Bearer $apiToken" }
    Check ($api.Status -eq 302) "    operator'ün Fatura Servisi token'ıyla (audience fatura-servisi): HTTP $($api.Status)"
}
$silenceBody = @{ matchers = @(@{ name = 'alertname'; value = 'Gun21Deneme'; isRegex = $false; isEqual = $true }); startsAt = (Get-Date).ToUniversalTime().ToString('o')
    endsAt = (Get-Date).AddMinutes(1).ToUniversalTime().ToString('o'); createdBy = 'gun21'; comment = 'önce/sonra denemesi' } | ConvertTo-Json -Depth 4
$silence = Send-Http POST 'http://localhost:9093/api/v2/silences' @{} $silenceBody
Check ($silence.Status -eq 302) "Alertmanager POST /api/v2/silences (alarm susturma), token'sız: HTTP $($silence.Status)"
$silenceId = Get-Field $silence.Body 'silenceID'
if ($silenceId) { [void](Send-Http DELETE "http://localhost:9093/api/v2/silence/$silenceId") }
$grafanaProxy = Send-Http GET 'http://localhost:3000/api/datasources/proxy/uid/prometheus/api/v1/query?query=up'
Check ($grafanaProxy.Status -eq 401) "Grafana üzerinden Prometheus sorgusu (veri kaynağı proxy'si), girişsiz: HTTP $($grafanaProxy.Status)"
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
