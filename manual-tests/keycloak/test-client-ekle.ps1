# Yalnızca yerel test için: kullanıcı adı ve şifreyle token veren fatura-test client'ını çalışan Keycloak'ın fatura
# realm'ine ekler (tanımı yanındaki fatura-test-client.json). Varsayılan kurulumda (keycloak/fatura-realm.json) bu client
# yoktur; kullanıcı token'ı alan test script'leri önce bunu çalıştırır. Client zaten varsa dokunulmaz. Keycloak'ın verisi
# container'ın içindedir: container yeniden yaratılınca (docker compose up -d --force-recreate keycloak) client da gider.
#   .\manual-tests\keycloak\test-client-ekle.ps1
param([string]$KeycloakUrl = 'http://localhost:8080')
$ErrorActionPreference = 'Stop'

# Keycloak'ın yönetim API'si, docker-compose.yml'deki yerel admin kullanıcısıyla; şifresi repo kökündeki .env'de.
$envLine = Get-Content (Join-Path $PSScriptRoot '..\..\.env') -Encoding UTF8 | Where-Object { $_ -cmatch '^KEYCLOAK_ADMIN_PASSWORD=.+' }
if (-not $envLine) { throw 'KEYCLOAK_ADMIN_PASSWORD .env dosyasında yok (repo kökünde .env.example''dan oluşturulur).' }
$adminPassword = $envLine.Substring('KEYCLOAK_ADMIN_PASSWORD='.Length).Trim()
$admin = (Invoke-RestMethod -Method Post -Uri "$KeycloakUrl/realms/master/protocol/openid-connect/token" -Body @{
    grant_type = 'password'; client_id = 'admin-cli'; username = 'admin'; password = $adminPassword }).access_token
$headers = @{ Authorization = "Bearer $admin" }
$clientsUrl = "$KeycloakUrl/admin/realms/fatura/clients"

$existing = Invoke-RestMethod -Uri "$clientsUrl`?clientId=fatura-test" -Headers $headers | ForEach-Object { $_ } |
    Where-Object { $_.clientId -eq 'fatura-test' }
if ($existing) { return }

$json = Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot 'fatura-test-client.json')
Invoke-RestMethod -Method Post -Uri $clientsUrl -Headers $headers -ContentType 'application/json; charset=utf-8' `
    -Body ([Text.Encoding]::UTF8.GetBytes($json)) | Out-Null
Write-Host "fatura-test client'ı eklendi (yalnızca bu Keycloak container'ında)."
