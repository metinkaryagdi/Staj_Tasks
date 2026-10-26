# Kontrol listesi 1 için: ekranda işlem yapılmadığında oturumun kapanması. Süre ayardan kısaltılır: yığın açılır, ekranın
# ayarındaki süre (operations-ui/src/config.ts, idleTimeoutMinutes = 15) yalnız derleme için <Dakika> yapılır ve dosya hemen
# geri alınır. Deneme tarayıcıda yapılır; -Oturum operatörün Keycloak'taki oturumlarını yazar (giriş yapılmışken ve süre
# dolduktan sonra çalıştırılır).
#   .\manual-tests\gun19\1-ekran-sure.ps1 -Hazirla            (yığın + ekran 2 dakikayla)
#   .\manual-tests\gun19\1-ekran-sure.ps1 -Oturum once        (giriş yapılmışken)
#   .\manual-tests\gun19\1-ekran-sure.ps1 -Oturum sonra       (süre dolduktan sonra)
#   .\manual-tests\gun19\1-ekran-sure.ps1 -Hazirla -Dakika 15 (ekranı ayardaki süreyle geri derler)
param([switch]$Hazirla, [int]$Dakika = 2, [ValidateSet('once', 'sonra')][string]$Oturum, [string]$User = 'operator')
. "$PSScriptRoot\_common.ps1"

if ($Hazirla) {
    Clear-SimulatorEnv
    Invoke-Compose @('up', '-d', '--build')
    $config = Join-Path $RepoRoot 'operations-ui\src\config.ts'
    $original = [IO.File]::ReadAllText($config)
    if ($original -notmatch 'export const idleTimeoutMinutes = \d+') { throw "config.ts'te idleTimeoutMinutes bulunamadı." }
    try {
        [IO.File]::WriteAllText($config, ($original -replace 'export const idleTimeoutMinutes = \d+', "export const idleTimeoutMinutes = $Dakika"))
        Invoke-Compose @('build', 'operations-ui')
    }
    finally { [IO.File]::WriteAllText($config, $original) }
    Invoke-Compose @('up', '-d', '--no-build', '--force-recreate', 'operations-ui')
    Wait-KeycloakAndService
    Write-Host "$(Get-Date -Format 'HH:mm:ss') Yığın hazır; ekran $Dakika dakikalık süreyle derlendi (config.ts geri alındı): http://localhost:5100"
    return
}

if (-not $Oturum) { throw '-Hazirla ya da -Oturum once|sonra verin.' }
New-Report "gun19-1-oturum-$Oturum"
Write-Title "Kontrol listesi 1) $User kullanıcısının Keycloak oturumları ($(if ($Oturum -eq 'once') { 'giriş yapılmışken' } else { 'süre dolduktan sonra' }))"
$u = @(Get-Admin "/users?username=$User&exact=true")[0]
$sessions = @(Get-Admin "/users/$($u.id)/sessions")
Write-Line "$(Get-Date -Format 'HH:mm:ss') ${User}: $($sessions.Count) oturum"
foreach ($s in $sessions) {
    Write-Line ("  başlangıç {0}, son erişim {1}, client {2}" -f (Format-Local ([DateTimeOffset]::FromUnixTimeMilliseconds($s.start))),
        (Format-Local ([DateTimeOffset]::FromUnixTimeMilliseconds($s.lastAccess))), (@($s.clients.PSObject.Properties.Value) -join ', '))
}
Write-Line ''
if ($Oturum -eq 'once') { Check ($sessions.Count -ge 1) 'ekranda giriş yapılmışken Keycloak''ta oturum var' }
else { Check ($sessions.Count -eq 0) 'süre dolduktan sonra Keycloak''ta oturum yok' }
Save-Report
Write-Result $script:AllPassed $(if ($Oturum -eq 'once') { 'Giriş yapılmışken Keycloak oturumu var.' } else { 'Süre dolduktan sonra Keycloak oturumu kapanmış.' })
