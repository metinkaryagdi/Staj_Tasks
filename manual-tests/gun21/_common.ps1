# Gün 21 (güvenlik bulgularını kapatmak) script'lerinin ortak yardımcıları. Gün 20'nin _common.ps1'ini yükler (token alma,
# API isteği, rapor dosyası, Keycloak yönetim API'si, Send-Http dahil). Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun20\_common.ps1"

# Bu güne özel volume'ler (staj-tasks_*-db-data-gun21); eski volume'lere dokunulmaz.
Use-Gun10Volumes 'gun21'

# Çıktılar günün klasörüne yazılır.
$OutputDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'output\gun21'
New-Item -ItemType Directory -Force $OutputDir | Out-Null

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
    [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Text = ("$($out[-1])" -replace '^psql: ', '').Trim() }
}

# Uygulamanın veritabanına bağlandığı kullanıcı ve şifre: container'ın ortamındaki bağlantı dizesinden okunur.
function Get-AppDbUser([string]$Service, [string]$Variable) {
    Push-Location $RepoRoot
    try { $connection = docker compose exec -T $Service printenv $Variable } finally { Pop-Location }
    $parts = @{}
    foreach ($pair in $connection.Split(';')) { $kv = $pair.Split('=', 2); if ($kv.Count -eq 2) { $parts[$kv[0].Trim()] = $kv[1] } }
    [pscustomobject]@{ User = $parts['Username']; Password = $parts['Password'] }
}

function Start-Stack {
    Push-Location $RepoRoot
    try { docker compose up -d --build 2>&1 | Out-Null } finally { Pop-Location }
    Wait-KeycloakAndService
}
