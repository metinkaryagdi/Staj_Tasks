# Kontrol listesi 6: Keycloak durdurulduğunda, önceden alınmış ve süresi dolmamış bir token'la API'ye istek. Açık yığında
# çalışır; hiçbir container'ı yeniden oluşturmaz, yalnızca durdurup başlatır. ~2 dk.
#   A) Keycloak durur: aynı token'la istek; yeni token istenir.
#   B) Keycloak kapalıyken Fatura Servisi yeniden başlar: aynı token'la istek (servisin bellekteki anahtarları gider).
#   C) Keycloak başlar: aynı token'la istek.
#   .\manual-tests\gun17\6-keycloak-durdur.ps1
. "$PSScriptRoot\_common.ps1"

New-Report 'gun17-6-keycloak-durdur'
Write-Title 'Kontrol listesi 6) Keycloak durunca önceden alınmış token'
Wait-KeycloakAndService
function Format-Local([DateTimeOffset]$At) { $At.ToLocalTime().ToString('HH:mm:ss') }
function Write-Request([string]$When) {
    $r = Send-Api GET '/api/v1/invoices/summary' $token
    $reason = if ($r.WwwAuthenticate -match 'error_description="([^"]+)"') { " ($($Matches[1]))" } else { '' }
    Write-Line ("  {0} {1}: GET /api/v1/invoices/summary -> HTTP {2}{3}" -f (Format-Local ([DateTimeOffset]::UtcNow)), $When, $r.Status, $reason)
    $r.Status
}

$token = Get-UserToken 'izleyici'
$expiresAt = [DateTimeOffset]::FromUnixTimeSeconds((Get-TokenClaims $token).exp)
Write-Line "İzleyici token'ı alındı; bitişi $(Format-Local $expiresAt) (+$ClockSkewSeconds sn tolerans)."
$before = Write-Request 'Keycloak açık'

$started = $false
try {
    Write-Step 'A) Keycloak durduruluyor'
    Invoke-Compose @('stop', 'keycloak')
    $a = Write-Request 'Keycloak kapalı'
    try { $null = Get-UserToken 'izleyici'; $newToken = 'alındı' } catch { $newToken = "alınamadı ($($_.Exception.Message))" }
    Write-Line "  Yeni token: $newToken"

    Write-Step 'B) Keycloak kapalıyken Fatura Servisi yeniden başlatılıyor'
    Invoke-Compose @('restart', 'invoice-service')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($true) { try { if ((Send-Api GET '/health').Status -gt 0) { break } } catch { }; if ($watch.Elapsed.TotalSeconds -gt 90) { throw 'Servis 90 sn içinde açılmadı.' }; Start-Sleep 1 }
    $b = Write-Request 'Keycloak kapalı, servis yeniden başladı'
    $log = @(Get-ServiceLog | Select-String -Pattern 'IDX\d+' | Select-Object -Last 1)
    if ($log) { Write-Line "  Servis logu: $(($log[0].Line -replace '^.*?(IDX\d+)', '$1').Substring(0, [Math]::Min(200, ($log[0].Line -replace '^.*?(IDX\d+)', '$1').Length)))" }

    Write-Step 'C) Keycloak başlatılıyor'
    Invoke-Compose @('start', 'keycloak'); $started = $true
    Wait-KeycloakAndService
    $c = Write-Request 'Keycloak yeniden açık'
}
finally { if (-not $started) { Invoke-Compose @('start', 'keycloak') } }

$stillValid = [DateTimeOffset]::UtcNow -lt $expiresAt
Write-Line ''
Write-Line "Token deneme boyunca geçerliydi: $(if ($stillValid) { 'evet' } else { 'hayır (C sonucu süre yüzünden olabilir)' })."
Save-Report
Write-Result ($before -eq 200 -and $a -eq 200 -and $newToken -ne 'alındı' -and $stillValid) `
    "Keycloak kapalıyken önceden alınmış geçerli token 200 aldı (servis anahtarları bellekte tutuyor); yeni token alınamadı. B: $b, C: $c."
