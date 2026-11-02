# Gün 21 (güvenlik bulgularını kapatmak) script'lerinin ortak yardımcıları. Gün 20'nin _common.ps1'ini yükler (token alma,
# API isteği, rapor dosyası, Keycloak yönetim API'si, Send-Http dahil). Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun20\_common.ps1"

# Bu güne özel volume'ler (staj-tasks_*-db-data-gun21); eski volume'lere dokunulmaz.
Use-Gun10Volumes 'gun21'

# Çıktılar günün klasörüne yazılır.
$OutputDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'output\gun21'
New-Item -ItemType Directory -Force $OutputDir | Out-Null

function Start-Stack {
    Push-Location $RepoRoot
    try { docker compose up -d --build 2>&1 | Out-Null } finally { Pop-Location }
    Wait-KeycloakAndService
}
