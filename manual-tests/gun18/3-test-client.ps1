# Kontrol listesi 3: varsayılan kurulumda fatura-test client'ı yok. Keycloak yeniden yaratılır (realm keycloak/'taki
# dosyadan yeniden kurulur; önceki test script'lerinin eklediği client da gider), sonra realm'in client'ları okunur. ~1 dk.
#   .\manual-tests\gun18\3-test-client.ps1
. "$PSScriptRoot\_common.ps1"

New-Report 'gun18-3-test-client'
Write-Title 'Kontrol listesi 3) Varsayılan kurulumda fatura-test yok'

Write-Step 'docker compose up -d --force-recreate keycloak'
Invoke-Compose @('up', '-d', '--force-recreate', 'keycloak')
Wait-KeycloakAndService
Push-Location $RepoRoot
try { $import = @(docker compose logs keycloak 2>&1 | ForEach-Object { "$_" } | Select-String -Pattern "Realm 'fatura' imported") }
finally { Pop-Location }
foreach ($l in $import) { Write-Line "Keycloak logu: $($l.Line -replace '^keycloak-1\s+\|\s+', '')" }

# Keycloak'ın her realm'e kendisi eklediği client'lar listede gösterilmez.
$builtIn = 'account', 'account-console', 'admin-cli', 'broker', 'realm-management', 'security-admin-console'
$clients = @(Get-Admin '/clients' | Where-Object { $_.clientId -notin $builtIn })
Write-Line ''
Write-Line 'fatura realm''inin client''ları (Keycloak''ın kendi client''ları hariç):'
foreach ($c in $clients) { Write-Line "  $($c.clientId)" }
Write-Line ''
Check ($import.Count -ge 1) 'realm dosyadan kuruldu'
Check (-not ($clients | Where-Object { $_.clientId -eq 'fatura-test' })) 'fatura-test yok'
Save-Report
Write-Result $script:AllPassed 'Varsayılan kurulumda fatura-test client''ı yok.'
