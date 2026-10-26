# Düzeltme 4 için: Gün 17'deki durumun aynısı, açık yığında. Önceden alınmış token'la istek; Keycloak durdurulur, Fatura
# Servisi yeniden başlatılır ve aynı token'la istek atılır (401); servisin logunda Keycloak'a ulaşılamadığını söyleyen satır
# aranır; Keycloak başlatılır ve aynı token'la istek (servis yeniden başlatılmadan). Hiçbir container yeniden oluşturulmaz. ~2 dk.
#   .\manual-tests\gun19\2-keycloak-kapali-log.ps1
. "$PSScriptRoot\_common.ps1"

New-Report 'gun19-2-keycloak-kapali-log'
Write-Title 'Düzeltme 4) Keycloak kapalıyken açılan servisin logu'
Wait-KeycloakAndService
function Write-Request([string]$When) {
    $r = Send-Api GET '/api/v1/invoices/summary' $token
    $reason = if ($r.WwwAuthenticate -match 'error_description="([^"]+)"') { " ($($Matches[1]))" } else { '' }
    Write-Line ("  {0} {1}: GET /api/v1/invoices/summary -> HTTP {2}{3}" -f (Get-Date -Format 'HH:mm:ss'), $When, $r.Status, $reason)
    $r.Status
}

$token = Get-UserToken 'izleyici'
$before = Write-Request 'Keycloak açık'
$started = $false
try {
    Invoke-Compose @('stop', 'keycloak')
    $restartedAt = [DateTimeOffset]::UtcNow
    Invoke-Compose @('restart', 'invoice-service')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($true) { try { if ((Send-Api GET '/health').Status -eq 200) { break } } catch { }; if ($watch.Elapsed.TotalSeconds -gt 90) { throw 'Servis 90 sn içinde açılmadı.' }; Start-Sleep 1 }
    $down = Write-Request 'Keycloak kapalı, servis yeniden başladı'

    Push-Location $RepoRoot
    try { $log = @(docker compose logs invoice-service --since $restartedAt.ToString('o') 2>&1 | ForEach-Object { "$_" } | Select-String -SimpleMatch 'Token rejected: Keycloak cannot be reached') }
    finally { Pop-Location }
    Write-Line "  Servis logunda satır: $($log.Count)"
    foreach ($l in $log | Select-Object -First 1) { Write-Line "    $($l.Line -replace '^invoice-service-1\s+\|\s+', '')" }

    Invoke-Compose @('start', 'keycloak'); $started = $true
    Wait-KeycloakAndService
    $up = Write-Request 'Keycloak yeniden açık (servis yeniden başlatılmadı)'
}
finally { if (-not $started) { Invoke-Compose @('start', 'keycloak') } }

Write-Line ''
Check ($before -eq 200) 'Keycloak açıkken token 200'
Check ($down -eq 401) 'Keycloak kapalıyken yeniden başlayan servis aynı token''a 401'
Check ($log.Count -ge 1) 'servisin logunda Keycloak''a ulaşılamadığını söyleyen satır var'
Check ($up -eq 200) 'Keycloak açılınca aynı token servis yeniden başlatılmadan 200'
Save-Report
Write-Result $script:AllPassed 'Keycloak kapalıyken açılan servis token''ı reddetti ve logda nedeni yazdı; Keycloak açılınca aynı token kabul edildi.'
