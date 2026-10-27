# Fatura Servisi 1'in audience ve issuer kontrolü (tablodaki imza ve süre kontrollerinin yanına): imzası geçerli ama
# audience'ı ya da issuer'ı tutmayan token 401 alır. Ayrıca açıklamada görünmeyen `/` (Swagger'a yönlendirme) de token ister.
# Açık yığında çalışır; yalnızca token alır ve GET atar. ~10 sn.
#   .\manual-tests\gun17\7-audience-issuer.ps1
. "$PSScriptRoot\_common.ps1"

New-Report 'gun17-7-audience-issuer'
Write-Title 'Fatura Servisi 1) audience ve issuer kontrolü'
Wait-KeycloakAndService
$allPassed = $true
function Check([bool]$Passed, [string]$Text) {
    Write-Line ("  [{0}] {1}" -f $(if ($Passed) { 'TAMAM' } else { 'FARKLI' }), $Text)
    if (-not $Passed) { $script:allPassed = $false }
}
function Test-Token([string]$What, [string]$Token, [int]$Expected) {
    $c = Get-TokenClaims $Token
    $r = Send-Api GET '/api/v1/invoices/summary' $Token
    $reason = if ($r.WwwAuthenticate -match 'error_description="([^"]+)"') { " ($($Matches[1]))" } else { '' }
    Write-Line ("  {0}: iss={1} aud={2}" -f $What, $c.iss, $(if ($c.aud) { @($c.aud) -join '+' } else { '(yok)' }))
    Check ($r.Status -eq $Expected) ("GET /api/v1/invoices/summary -> HTTP {0}{1}" -f $r.Status, $reason)
}

Write-Line 'Token''lar (hepsi Keycloak''ın kendi anahtarıyla imzalı; izleyici rolü yalnızca birincide):'
Test-Token "1) fatura realm'i, fatura-test client'ı, izleyici" (Get-UserToken 'izleyici') 200
# Keycloak her realm'e kendi admin-cli client'ını ekler; onda fatura-servisi audience mapper'ı yoktur.
$wrongAudience = (Invoke-RestMethod -Method Post -Uri $TokenUrl -Body @{
    grant_type = 'password'; client_id = 'admin-cli'; username = 'izleyici'; password = $TestUsers['izleyici'] }).access_token
Test-Token "2) fatura realm'i, admin-cli client'ı (audience mapper yok), izleyici" $wrongAudience 401
$otherIssuer = (Invoke-RestMethod -Method Post -Uri "$KeycloakUrl/realms/master/protocol/openid-connect/token" -Body @{
    grant_type = 'password'; client_id = 'admin-cli'; username = 'admin'; password = (Get-DotEnvValue 'KEYCLOAK_ADMIN_PASSWORD') }).access_token
Test-Token "3) master realm'i (başka issuer), admin" $otherIssuer 401

Write-Line ''
Write-Line '`/` (Swagger''a yönlendirme; API açıklamasında yok):'
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $false
$noRedirect = New-Object System.Net.Http.HttpClient($handler)
$anonymous = [int]$noRedirect.GetAsync("$ServiceUrl/").GetAwaiter().GetResult().StatusCode
Check ($anonymous -eq 401) "token yok -> HTTP $anonymous"
$request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, "$ServiceUrl/")
$request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', (Get-UserToken 'rolsuz'))
$withToken = [int]$noRedirect.SendAsync($request).GetAwaiter().GetResult().StatusCode
Check ($withToken -eq 302) "rolsüz kullanıcının geçerli token'ı -> HTTP $withToken (yönlendirme; rol istemez)"

Save-Report
Write-Result $allPassed 'Audience''ı ya da issuer''ı tutmayan token 401; `/` da token istiyor.'
