# Kontrol listesi 1: compose ayağa kalktıktan sonra realm, roller, client'lar ve üç kullanıcı elle hiçbir işlem
# yapılmadan hazır. Bütün yığın bu güne özel boş volume'lerle yeniden oluşturulur (Keycloak realm'i keycloak/'tan kurar).
#   .\manual-tests\gun17\1-hazir.ps1
. "$PSScriptRoot\_common.ps1"

New-Report 'gun17-1-hazir'
Write-Title 'Kontrol listesi 1) Compose sonrası realm, roller, client''lar ve kullanıcılar'
$allPassed = $true
function Check([bool]$Passed, [string]$Text) {
    Write-Line ("  [{0}] {1}" -f $(if ($Passed) { 'TAMAM' } else { 'FARKLI' }), $Text)
    if (-not $Passed) { $script:allPassed = $false }
}

Write-Step 'docker compose up -d --build --force-recreate (boş gun17 volume''leri)'
Clear-SimulatorEnv
$startedAt = Get-Date
Invoke-Compose @('up', '-d', '--build', '--force-recreate')
Wait-KeycloakAndService
Write-Line ("Yığın {0} içinde hazır ({1:HH:mm:ss})." -f (Format-Duration ((Get-Date) - $startedAt).TotalSeconds), (Get-Date))

Write-Line ''
Write-Line 'Keycloak logu (import):'
Push-Location $RepoRoot
try { $import = @(docker compose logs keycloak 2>&1 | ForEach-Object { "$_" } | Select-String -Pattern "Realm 'fatura' imported|already exists") }
finally { Pop-Location }
foreach ($l in $import) { Write-Line "  $($l.Line -replace '^keycloak-1\s+\|\s+', '')" }
Check ($import.Count -ge 1 -and $import[-1].Line -match 'imported') "Realm 'fatura' dosyadan kuruldu"

# Keycloak'ın yönetim API'si (compose'daki admin kullanıcısıyla, yalnızca okuma).
$admin = (Invoke-RestMethod -Method Post -Uri "$KeycloakUrl/realms/master/protocol/openid-connect/token" -Body @{
    grant_type = 'password'; client_id = 'admin-cli'; username = 'admin'; password = 'admin' }).access_token
$h = @{ Authorization = "Bearer $admin" }
function Get-Admin([string]$Path) { @(Invoke-RestMethod -Uri "$KeycloakUrl/admin/realms/fatura$Path" -Headers $h) | ForEach-Object { $_ } }

Write-Line ''
Write-Line 'Realm içeriği (Keycloak yönetim API''si):'
$roles = @(Get-Admin '/roles' | ForEach-Object { $_.name })
foreach ($role in 'fatura-izleyici', 'fatura-operatoru', 'fatura-olusturucu') { Check ($role -in $roles) "rol $role" }
$clients = @(Get-Admin '/clients')
$test = $clients | Where-Object { $_.clientId -eq 'fatura-test' }
$order = $clients | Where-Object { $_.clientId -eq 'siparis-sistemi' }
Check ($test -and $test.publicClient -and $test.directAccessGrantsEnabled) 'client fatura-test (secret yok, yalnızca kullanıcı adı ve şifreyle token)'
Check ($order -and -not $order.publicClient -and $order.serviceAccountsEnabled -and -not $order.directAccessGrantsEnabled) `
    'client siparis-sistemi (secret ile, yalnızca client credentials)'
$users = @(Get-Admin '/users?max=100')
foreach ($expected in @(@('izleyici', 'fatura-izleyici'), @('operator', 'fatura-operatoru'), @('rolsuz', $null))) {
    $u = $users | Where-Object { $_.username -eq $expected[0] }
    $userRoles = if ($u) { @(Get-Admin "/users/$($u.id)/role-mappings/realm" | ForEach-Object { $_.name }) } else { @() }
    $faturaRoles = @($userRoles | Where-Object { $_ -like 'fatura-*' })
    $ok = $u -and $(if ($expected[1]) { $faturaRoles.Count -eq 1 -and $faturaRoles[0] -eq $expected[1] } else { $faturaRoles.Count -eq 0 })
    Check $ok ("kullanıcı {0}: rolleri {1}" -f $expected[0], $(if ($faturaRoles.Count) { $faturaRoles -join ', ' } else { 'yok' }))
}

Write-Line ''
Write-Line 'Token''lar (aud, rol, issuer):'
foreach ($user in $TestUsers.Keys) {
    $c = Get-TokenClaims (Get-UserToken $user)
    $faturaRoles = @($c.realm_access.roles | Where-Object { $_ -like 'fatura-*' })
    Write-Line ("  {0,-16} preferred_username={1} aud={2} roller={3} iss={4} ömür={5} sn" -f $user, $c.preferred_username,
        ($c.aud -join '+'), $(if ($faturaRoles.Count) { $faturaRoles -join ',' } else { '-' }), $c.iss, ($c.exp - $c.iat))
}
$c = Get-TokenClaims (Get-OrderSystemToken)
Write-Line ("  {0,-16} preferred_username={1} aud={2} roller={3} iss={4} ömür={5} sn" -f 'siparis-sistemi', $c.preferred_username,
    ($c.aud -join '+'), (@($c.realm_access.roles | Where-Object { $_ -like 'fatura-*' }) -join ','), $c.iss, ($c.exp - $c.iat))
Check ('fatura-servisi' -in @($c.aud) -and 'fatura-olusturucu' -in @($c.realm_access.roles)) 'siparis-sistemi token''ı: aud fatura-servisi, rol fatura-olusturucu'

Save-Report
Write-Result $allPassed 'Compose sonrası realm, roller, client''lar ve üç kullanıcı elle işlem yapılmadan hazır.'
