# Gün 17 (Keycloak ve JWT) script'lerinin ortak yardımcıları. Gün 10'un _common.ps1'ini de yükler (Gün 1-9 yardımcıları
# dahil). Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun10\_common.ps1"

# Kontrol listesi boş veritabanıyla başlar: compose bu güne özel volume'lerle açılır (staj-tasks_*-db-data-gun17); eski
# volume'ler silinmez, dokunulmaz.
Use-Gun10Volumes 'gun17'

$KeycloakUrl = 'http://localhost:8080'
$TokenUrl = "$KeycloakUrl/realms/fatura/protocol/openid-connect/token"
# keycloak/fatura-realm.json'daki test değerleri.
$TestUsers = [ordered]@{ izleyici = 'izleyici123'; operator = 'operator123'; rolsuz = 'rolsuz123' }
$OrderSystemSecret = 'dev-only-siparis-sistemi-secret-do-not-use-in-production'
# Fatura Servisi'nin Keycloak:ClockSkewSeconds ayarı (appsettings.json): süresi dolan token bu kadar daha kabul edilir.
$ClockSkewSeconds = 30

# Token'ı kendimiz koyduğumuz istemci: ortak istemci her isteğe X-Operator-Name ekler.
$script:ApiHttp = New-Object System.Net.Http.HttpClient
$script:ApiHttp.Timeout = [TimeSpan]::FromMinutes(2)

# Kullanıcı token'ı fatura-test client'ından şifreyle alınır. Bu client varsayılan kurulumda yoktur: ilk token'dan önce
# yalnızca bu yerel Keycloak'a eklenir (manual-tests\keycloak\test-client-ekle.ps1).
$script:TestClientReady = $false
function Get-UserToken([string]$User) {
    if (-not $script:TestClientReady) {
        & "$PSScriptRoot\..\keycloak\test-client-ekle.ps1" -KeycloakUrl $KeycloakUrl
        $script:TestClientReady = $true
    }
    (Invoke-RestMethod -Method Post -Uri $TokenUrl -Body @{
        grant_type = 'password'; client_id = 'fatura-test'; username = $User; password = $TestUsers[$User] }).access_token
}

function Get-OrderSystemToken {
    (Invoke-RestMethod -Method Post -Uri $TokenUrl -Body @{
        grant_type = 'client_credentials'; client_id = 'siparis-sistemi'; client_secret = $OrderSystemSecret }).access_token
}

function ConvertFrom-Base64Url([string]$Text) {
    $b = $Text.Replace('-', '+').Replace('_', '/')
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b.PadRight($b.Length + (4 - $b.Length % 4) % 4, '=')))
}

# Token'ın içeriği (imzası doğrulanmadan, yalnızca okumak için).
function Get-TokenClaims([string]$Token) { ConvertFrom-Base64Url $Token.Split('.')[1] | ConvertFrom-Json }

# İmzası bozuk token: içerikteki operatör rolü sipariş sisteminin rolüyle değiştirilir, imza aynı bırakılır.
function New-TamperedToken([string]$Token) {
    $parts = $Token.Split('.')
    $json = (ConvertFrom-Base64Url $parts[1]).Replace('"fatura-operatoru"', '"fatura-olusturucu"')
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    "$($parts[0]).$payload.$($parts[2])"
}

# Fatura Servisi'ne istek. $Token $null ise Authorization gönderilmez; $Headers ek başlıklar. Status, Body, Json, Code ve
# WwwAuthenticate (401'in nedeni) döner.
function Send-Api([string]$Method, [string]$Path, $Token = $null, $Json = $null, [hashtable]$Headers = @{}) {
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), "$ServiceUrl$Path")
    if ($Token) { $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token) }
    foreach ($key in $Headers.Keys) { [void]$request.Headers.TryAddWithoutValidation($key, $Headers[$key]) }
    if ($null -ne $Json) { $request.Content = [Net.Http.StringContent]::new($Json, [Text.Encoding]::UTF8, 'application/json') }
    $response = $script:ApiHttp.SendAsync($request).GetAwaiter().GetResult()
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $parsed = $null
    try { if ($body -and $body.TrimStart().StartsWith('{')) { $parsed = $body | ConvertFrom-Json } } catch { }
    [pscustomobject]@{ Status = [int]$response.StatusCode; Body = $body; Json = $parsed; Code = $parsed.code
        WwwAuthenticate = "$($response.Headers.WwwAuthenticate)" }
}

# Keycloak'ın realm'i yayımlaması ve Fatura Servisi'nin cevap vermesi beklenir. /health token istemez; cevap vermesi servisin
# açık olduğunu gösterir.
function Wait-KeycloakAndService([int]$TimeoutSeconds = 180) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $keycloak = $false; $service = $false
        try { $keycloak = (Invoke-WebRequest -UseBasicParsing "$KeycloakUrl/realms/fatura/.well-known/openid-configuration" -TimeoutSec 3).StatusCode -eq 200 } catch { }
        try { $service = (Send-Api GET '/health').Status -in 200, 401 } catch { }
        if ($keycloak -and $service) { return }
        if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw "Keycloak ($keycloak) ve Fatura Servisi ($service) $TimeoutSeconds sn içinde hazır olmadı." }
        Start-Sleep -Seconds 2
    }
}

# Ekrana yazılan her satır rapor dosyasına da yazılır (manual-tests\output\<Name>.txt).
function New-Report([string]$Name) {
    $script:ReportFile = Join-Path $OutputDir "$Name.txt"
    $script:ReportLines = [Collections.Generic.List[string]]::new()
}
function Write-Line([string]$Text = '') { Write-Host $Text; $script:ReportLines.Add($Text) }
function Save-Report {
    [IO.File]::WriteAllLines($script:ReportFile, $script:ReportLines, [Text.UTF8Encoding]::new($true))
    Write-Host "Rapor: $script:ReportFile"
}
