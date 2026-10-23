# Gün 18 (operasyon ekranına giriş) script'lerinin ortak yardımcıları. Gün 17'nin _common.ps1'ini yükler (token alma,
# API isteği, rapor dosyası, Gün 1-10 yardımcıları dahil). Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun17\_common.ps1"

# Kontrol listesi bu güne özel volume'lerle çalışır (staj-tasks_*-db-data-gun18); eski volume'lere dokunulmaz.
Use-Gun10Volumes 'gun18'

$script:AllPassed = $true
function Check([bool]$Passed, [string]$Text) {
    Write-Line ("  [{0}] {1}" -f $(if ($Passed) { 'TAMAM' } else { 'FARKLI' }), $Text)
    if (-not $Passed) { $script:AllPassed = $false }
}

# Keycloak'ın yönetim API'si (docker-compose.yml'deki yerel admin kullanıcısıyla). $Path fatura realm'ine göre.
function Get-Admin([string]$Path) {
    $admin = (Invoke-RestMethod -Method Post -Uri "$KeycloakUrl/realms/master/protocol/openid-connect/token" -Body @{
        grant_type = 'password'; client_id = 'admin-cli'; username = 'admin'; password = 'admin' }).access_token
    Invoke-RestMethod -Uri "$KeycloakUrl/admin/realms/fatura$Path" -Headers @{ Authorization = "Bearer $admin" } |
        ForEach-Object { $_ }
}

function Format-Local([DateTimeOffset]$At) { $At.ToLocalTime().ToString('HH:mm:ss') }
