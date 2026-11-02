# Gün 21 (güvenlik bulgularını kapatmak) script'lerinin ortak yardımcıları. Gün 20'nin _common.ps1'ini yükler (token alma,
# API isteği, rapor dosyası, Keycloak yönetim API'si, Send-Http dahil). Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun20\_common.ps1"

# Bu güne özel volume'ler (staj-tasks_*-db-data-gun21); eski volume'lere dokunulmaz.
Use-Gun10Volumes 'gun21'

# Çıktılar günün klasörüne yazılır.
$OutputDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'output\gun21'
New-Item -ItemType Directory -Force $OutputDir | Out-Null

# Send-Http'nin istemcisi çerez saklamaz: bir istekte alınan oturum (ör. Grafana girişi) sonraki "girişsiz" isteğe
# taşınmasın.
$script:PlainHttp = [Net.Http.HttpClient]::new([Net.Http.HttpClientHandler]@{ AllowAutoRedirect = $false; UseCookies = $false })
$script:PlainHttp.Timeout = [TimeSpan]::FromSeconds(15)

# Keycloak'ın yönetim API'sine istek; hata kodları da exception'sız döner (Send-Http). $Path fatura realm'ine göre.
function Send-Admin([string]$Method, [string]$Path, $Json = $null) {
    $admin = (Invoke-RestMethod -Method Post -Uri "$KeycloakUrl/realms/master/protocol/openid-connect/token" -Body @{
        grant_type = 'password'; client_id = 'admin-cli'; username = 'admin'; password = (Get-DotEnvValue 'KEYCLOAK_ADMIN_PASSWORD') }).access_token
    Send-Http $Method "$KeycloakUrl/admin/realms/fatura$Path" @{ Authorization = "Bearer $admin" } $Json
}

# Bir container'daki psql: veritabanına compose ağındaki adıyla ve verilen kullanıcı/şifreyle bağlanır (container'ın kendi
# 127.0.0.1'i şifre sormaz, ağ adı sorar). Çıktının son satırını ve başarılı olup olmadığını döner.
function Invoke-Psql([string]$Service, [string]$User, [string]$Password, [string]$Database, [string]$Sql) {
    Push-Location $RepoRoot
    try { $out = @(docker compose exec -T -e "PGPASSWORD=$Password" $Service psql -h $Service -U $User -d $Database -v ON_ERROR_STOP=1 -tAc $Sql 2>&1) }
    finally { Pop-Location }
    # stderr ve stdout karışık sırayla gelir: hata varsa hata satırı gösterilir.
    $errorLine = @($out | ForEach-Object { "$_" } | Where-Object { $_ -match 'ERROR:|FATAL:|DETAIL:' }) | Select-Object -Last 1
    [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Text = ("$(if ($errorLine) { $errorLine } else { $out[-1] })" -replace '^psql: ', '').Trim() }
}

# Uygulamanın veritabanına bağlandığı kullanıcı ve şifre: container'ın ortamındaki bağlantı dizesinden okunur.
function Get-AppDbUser([string]$Service, [string]$Variable) {
    Push-Location $RepoRoot
    try { $connection = docker compose exec -T $Service printenv $Variable } finally { Pop-Location }
    $parts = @{}
    foreach ($pair in $connection.Split(';')) { $kv = $pair.Split('=', 2); if ($kv.Count -eq 2) { $parts[$kv[0].Trim()] = $kv[1] } }
    [pscustomobject]@{ User = $parts['Username']; Password = $parts['Password'] }
}

# Tarayıcının giriş akışı (Authorization Code + PKCE): giriş formu kullanıcı adı ve şifreyle gönderilir, dönen kod token'la
# değiştirilir. Keycloak isteği formu göstermeden reddederse (ör. error=invalid_scope) Status 'reddedildi' olur. Keycloak'ın
# oturum çerezleri elle taşınır: Windows PowerShell'in CookieContainer'ı bu çerezleri (Version=1, SameSite) kaydetmiyor.
function Get-AuthCodeTokens([string]$ClientId, [string]$Redirect, [string]$Scope, [string]$UserName, [string]$Password, [string]$ClientSecret = '') {
    $form = 'application/x-www-form-urlencoded'
    $browser = [Net.Http.HttpClient]::new([Net.Http.HttpClientHandler]@{ AllowAutoRedirect = $false; UseCookies = $false })
    $verifier = -join ((1..64) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
    $challenge = [Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $redirectParam = [Uri]::EscapeDataString($Redirect)
    $authUrl = "$KeycloakUrl/realms/fatura/protocol/openid-connect/auth?client_id=$ClientId&response_type=code" +
        "&scope=$([Uri]::EscapeDataString($Scope))&redirect_uri=$redirectParam&state=gun21&code_challenge=$challenge&code_challenge_method=S256"
    $loginPage = $browser.GetAsync($authUrl).GetAwaiter().GetResult()
    $authError = [regex]::Match("$($loginPage.Headers.Location)", '[?&]error=([^&]+)&error_description=([^&]+)')
    if ($authError.Success) {
        Write-Line "  $ClientId girişi, scope '$Scope': Keycloak reddetti, $($authError.Groups[1].Value): $([Uri]::UnescapeDataString($authError.Groups[2].Value.Replace('+', ' ')))"
        return [pscustomobject]@{ Status = 'reddedildi'; Access = $null; Refresh = $null; Type = $null }
    }
    $page = $loginPage.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $cookies = ($loginPage.Headers.GetValues('Set-Cookie') | ForEach-Object { $_.Split(';')[0] }) -join '; '
    $action = [Net.WebUtility]::HtmlDecode([regex]::Match($page, 'id="kc-form-login"[^>]*action="([^"]+)"').Groups[1].Value)
    $loginPost = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $action)
    $loginPost.Content = [Net.Http.StringContent]::new("username=$UserName&password=$([Uri]::EscapeDataString($Password))&credentialId=", [Text.Encoding]::UTF8, $form)
    [void]$loginPost.Headers.TryAddWithoutValidation('Cookie', $cookies)
    $posted = $browser.SendAsync($loginPost).GetAwaiter().GetResult()
    $code = [regex]::Match("$($posted.Headers.Location)", '[?&]code=([^&]+)').Groups[1].Value
    $secret = if ($ClientSecret) { "&client_secret=$ClientSecret" } else { '' }
    $tokens = Send-Http POST $TokenUrl @{} "grant_type=authorization_code&client_id=$ClientId$secret&code=$code&redirect_uri=$redirectParam&code_verifier=$verifier" $form
    $json = if ($tokens.Status -eq 200) { $tokens.Body | ConvertFrom-Json } else { $null }
    Write-Line "  $ClientId girişi ($UserName), scope '$Scope': HTTP $($tokens.Status), verilen scope '$($json.scope)' $(try { ($tokens.Body | ConvertFrom-Json).error_description } catch { })"
    [pscustomobject]@{ Status = $tokens.Status; Access = $json.access_token; Refresh = $json.refresh_token
        Type = $(if ($json) { (Get-TokenClaims $json.refresh_token).typ }) }
}

function Start-Stack {
    Push-Location $RepoRoot
    try { docker compose up -d --build 2>&1 | Out-Null } finally { Pop-Location }
    Wait-KeycloakAndService
}
