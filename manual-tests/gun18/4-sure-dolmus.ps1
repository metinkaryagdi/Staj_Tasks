# Kontrol listesi 4: süresi dolmuş bir token 30 saniye sonra 401 alıyor (Keycloak:ClockSkewSeconds = 30). Açık yığında
# çalışır. ~6 dk: sipariş sisteminin token'ının ömrü (5 dk) ve 30 sn tolerans beklenir.
#   .\manual-tests\gun18\4-sure-dolmus.ps1
. "$PSScriptRoot\_common.ps1"

New-Report 'gun18-4-sure-dolmus'
Write-Title 'Kontrol listesi 4) Süresi dolmuş token 30 sn sonra 401'
Wait-KeycloakAndService

$token = Get-OrderSystemToken
$expiresAt = [DateTimeOffset]::FromUnixTimeSeconds((Get-TokenClaims $token).exp)
Write-Line "Sipariş sisteminin token'ı alındı $(Format-Local ([DateTimeOffset]::UtcNow)); bitişi $(Format-Local $expiresAt), tolerans $ClockSkewSeconds sn."
$askAt = $expiresAt.AddSeconds($ClockSkewSeconds + 2)
$wait = [math]::Ceiling(($askAt - [DateTimeOffset]::UtcNow).TotalSeconds)
Write-Step "$wait sn bekleniyor (bitiş + $ClockSkewSeconds sn + 2 sn: $(Format-Local $askAt))"
Start-Sleep -Seconds $wait

$body = '{"customerCode":"GUN18-SURE","amount":10.5,"currency":"TRY","invoiceDate":"2026-10-23"}'
$r = Send-Api POST '/api/v1/invoices' $token $body
$reason = if ($r.WwwAuthenticate -match 'error_description="([^"]+)"') { $Matches[1] } else { '' }
$late = [math]::Round(([DateTimeOffset]::UtcNow - $expiresAt).TotalSeconds)
Write-Line "$(Format-Local ([DateTimeOffset]::UtcNow)) (bitişten $late sn sonra) POST /api/v1/invoices -> HTTP $($r.Status)"
Write-Line "  WWW-Authenticate: $($r.WwwAuthenticate)"
Write-Line ''
Check ($r.Status -eq 401 -and $reason -match 'expired') "HTTP $($r.Status), neden: $reason"
Save-Report
Write-Result $script:AllPassed "Süresi dolmuş token bitişten $ClockSkewSeconds sn sonra 401 aldı."
