# Kontrol listesi 8 için: kullanıcının Keycloak'taki oturumları (Keycloak yönetim API'si). Ekranda Çıkış'tan önce ve sonra
# çalıştırılır; çıkıştan sonra oturum kalmaz. Açık yığında çalışır.
#   .\manual-tests\gun18\8-oturum.ps1 -When once
#   .\manual-tests\gun18\8-oturum.ps1 -When sonra
param([string]$User = 'operator', [Parameter(Mandatory)][ValidateSet('once', 'sonra')][string]$When)
. "$PSScriptRoot\_common.ps1"

New-Report "gun18-8-oturum-$When"
Write-Title "Kontrol listesi 8) $User kullanıcısının Keycloak oturumları ($(if ($When -eq 'once') { 'çıkıştan önce' } else { 'çıkıştan sonra' }))"
$u = @(Get-Admin "/users?username=$User&exact=true")[0]
$sessions = @(Get-Admin "/users/$($u.id)/sessions")
Write-Line "$(Get-Date -Format 'HH:mm:ss') ${User}: $($sessions.Count) oturum"
foreach ($s in $sessions) {
    Write-Line ("  başlangıç {0}, son erişim {1}, client {2}" -f (Format-Local ([DateTimeOffset]::FromUnixTimeMilliseconds($s.start))),
        (Format-Local ([DateTimeOffset]::FromUnixTimeMilliseconds($s.lastAccess))), (@($s.clients.PSObject.Properties.Value) -join ', '))
}
Write-Line ''
if ($When -eq 'once') { Check ($sessions.Count -ge 1) 'ekranda giriş yapılmışken Keycloak''ta oturum var' }
else { Check ($sessions.Count -eq 0) 'çıkıştan sonra Keycloak''ta oturum yok' }
Save-Report
Write-Result $script:AllPassed $(if ($When -eq 'once') { 'Giriş yapılmışken Keycloak oturumu var.' } else { 'Çıkıştan sonra Keycloak oturumu kapanmış.' })
