# Kontrol listesi 6: loglarda token, şifre ve secret geçmiyor. Gönderilen ayarlarla (log seviyeleri değiştirilmeden) token'lı,
# token'sız, bozuk token'lı istekler, imzalı/imzasız webhook'lar ve şifreli girişler yapılır; sonra yığındaki bütün
# container'ların o andan sonraki logları, ardından şu anki container'ların açılışından bu yana bütün logları aranır. Aranan: bu koşuda alınan
# token'ların kendisi, her JWT biçimi (eyJ...), "Bearer", Authorization başlığı ve .env'deki her şifre/secret değeri. ~1 dk.
# -AyrintiliLog: aynı koşu kimlik doğrulama Debug ve EF SQL logu açıkken (compose.ayrintili-log.yml); bir mutabakat da
# başlatılır. Bu koşunun logu 3-ham-sql.ps1'in girdisidir. Sonunda servisler gönderilen ayarlarla yeniden açılır.
#   .\manual-tests\gun20\2-log-arama.ps1
#   .\manual-tests\gun20\2-log-arama.ps1 -AyrintiliLog
param([switch]$AyrintiliLog)
. "$PSScriptRoot\_common.ps1"

$reportName = if ($AyrintiliLog) { 'b-log-arama-ayrintili' } else { 'b-log-arama' }
New-Report $reportName
Write-Title "Kontrol listesi 6) Loglarda token, şifre ve secret yok$(if ($AyrintiliLog) { ' (ayrıntılı log)' })"
$shippedComposeFile = $env:COMPOSE_FILE
if ($AyrintiliLog) { $env:COMPOSE_FILE = "$shippedComposeFile;$(Join-Path $PSScriptRoot 'compose.ayrintili-log.yml')" }
Push-Location $RepoRoot
try { docker compose up -d 2>&1 | Out-Null } finally { Pop-Location }
Wait-KeycloakAndService
$since = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
Write-Line "Logların başlangıcı (UTC): $since"

Write-Line ''
Write-Line 'İstekler:'
$tokens = [ordered]@{}
$tokens['sipariş sistemi'] = Get-OrderSystemToken
foreach ($user in 'izleyici', 'operator', 'rolsuz') { $tokens[$user] = Get-UserToken $user }
$created = Send-Api POST '/api/v1/invoices' $tokens['sipariş sistemi'] '{"customerCode":"GUN20-LOG","amount":10.5,"currency":"TRY","invoiceDate":"2026-10-27"}'
$number = $created.Json.invoiceNumber
Write-Line "  fatura oluşturma (sipariş sistemi token'ı): HTTP $($created.Status) $number"
foreach ($user in 'izleyici', 'operator', 'rolsuz') {
    Write-Line "  özet ($user token'ı): HTTP $((Send-Api GET '/api/v1/invoices/summary' $tokens[$user]).Status)"
}
Write-Line "  yeniden gönderme (operatör token'ı): HTTP $((Send-Api POST "/api/v1/invoices/$number/resend" $tokens['operator']).Status)"
Write-Line "  izleyici token'ıyla yeniden gönderme: HTTP $((Send-Api POST "/api/v1/invoices/$number/resend" $tokens['izleyici']).Status)"
Write-Line "  imzası bozuk token: HTTP $((Send-Api GET '/api/v1/invoices/summary' (New-TamperedToken $tokens['operator'])).Status)"
Write-Line "  token'sız: HTTP $((Send-Api GET '/api/v1/invoices/summary').Status)"
Write-Line "  Authorization: Basic (şifre): HTTP $((Send-Api GET '/api/v1/invoices/summary' $null $null @{ Authorization = (Get-BasicAuth 'operator' $TestUsers['operator']) }).Status)"
$wrongLogin = Send-Http POST $TokenUrl @{} 'grant_type=password&client_id=fatura-test&username=operator&password=yanlis-sifre-gun20' 'application/x-www-form-urlencoded'
Write-Line "  Keycloak'a yanlış şifreyle giriş: HTTP $($wrongLogin.Status)"
$secret = Get-WebhookSecret
$body = [Text.Encoding]::UTF8.GetBytes((New-WebhookBody "gun20-log-$(Get-Date -Format 'HHmmss')" 'invoice.received' 'FTR-GUN20-LOG' 'ERP-GUN20' $null))
$ts = [string](Get-UnixNow)
Write-Line "  imzalı webhook: HTTP $((Send-Webhook $body $ts (Get-WebhookSignature $secret $ts $body)).Status)"
Write-Line "  yanlış imzalı webhook: HTTP $((Send-Webhook $body $ts (Get-WebhookSignature 'yanlis-anahtar-yanlis-anahtar-yanlis-anahtar' $ts $body)).Status)"
if ($AyrintiliLog) {
    Write-Line "  mutabakat başlatma (operatör token'ı): HTTP $((Send-Api POST '/api/v1/reconciliation-runs' $tokens['operator']).Status)"
}
Write-Line '  Outbox, mutabakat ve simülatör webhook''larının loglanması için 15 sn beklenir.'
Start-Sleep -Seconds 15

Push-Location $RepoRoot
try {
    $lines = @(docker compose logs --no-color --since $since 2>&1 | ForEach-Object { "$_" })
    # Şu anki container'ların açılışından bu yana bütün loglar; -AyrintiliLog'da servisler geri alınmadan önce okunur.
    $all = @(docker compose logs --no-color 2>&1 | ForEach-Object { "$_" })
} finally { Pop-Location }
if ($AyrintiliLog) {
    $env:COMPOSE_FILE = $shippedComposeFile
    Push-Location $RepoRoot
    try { docker compose up -d 2>&1 | Out-Null } finally { Pop-Location }
}
$logFile = Join-Path $OutputDir "$reportName-loglar.txt"
[IO.File]::WriteAllLines($logFile, $lines, [Text.UTF8Encoding]::new($true))
$services = @($lines | ForEach-Object { if ($_ -match '^(\S+?)-\d+\s+\|') { $Matches[1] } } | Sort-Object -Unique)
Write-Line ''
Write-Line "Aranan loglar: $($lines.Count) satır, $($services.Count) container ($($services -join ', ')); tamamı $(Split-Path $logFile -Leaf)"

$searches = [ordered]@{}
foreach ($name in $tokens.Keys) { $searches["bu koşuda alınan $name token'ı"] = [regex]::Escape($tokens[$name]) }
foreach ($name in $tokens.Keys) { $searches["$name token'ının imza kısmı"] = [regex]::Escape($tokens[$name].Split('.')[2]) }
$searches['herhangi bir JWT (eyJ...eyJ...)'] = 'eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}'
$searches['"Bearer " ve ardından bir değer'] = 'Bearer\s+[A-Za-z0-9_\-\.]{10,}'
$searches['Authorization başlığı'] = '(?i)authorization\s*[:=]'
# .env'deki her şifre ve secret kendi değeriyle (veritabanı şifreleri, Keycloak yönetici şifresi, webhook ve client secret'ı,
# test kullanıcılarının şifreleri).
foreach ($line in Get-Content (Join-Path $RepoRoot '.env') -Encoding UTF8) {
    if ($line -cmatch '^([A-Z_]+)=(.+)$') { $searches[".env: $($Matches[1])"] = [regex]::Escape($Matches[2].Trim()) }
}
$searches['yanlış girilen şifre'] = 'yanlis-sifre-gun20'
$searches['Basic kimlik bilgisi'] = [regex]::Escape((Get-BasicAuth 'operator' $TestUsers['operator']).Substring(6))
$searches['bağlantı dizesindeki şifre (Password=)'] = '(?i)password\s*='
$searches['client_secret / password parametresi'] = '(?i)(client_secret|[?&]password)='

Write-Line ''
Write-Line 'Arama: aranan | eşleşen satır'
foreach ($name in $searches.Keys) {
    $hits = @($lines | Where-Object { $_ -match $searches[$name] })
    Check ($hits.Count -eq 0) ("{0,-48} {1}" -f $name, $hits.Count)
    foreach ($hit in ($hits | Select-Object -First 3)) { Write-Line "      $($hit.Substring(0, [Math]::Min(200, $hit.Length)))" }
}
$rejected = @($lines | Where-Object { $_ -match 'invoice-service' -and $_ -match '(?i)(Bearer was not authenticated|token|IDX\d+)' })
Write-Line ''
Write-Line "Fatura Servisi'nin token'la ilgili log satırları (token içermediğini görmek için, ilk 5 / $($rejected.Count)):"
foreach ($line in ($rejected | Select-Object -First 5)) { Write-Line "  $($line.Substring(0, [Math]::Min(220, $line.Length)))" }

# Yukarıdaki pencere istekler başladıktan sonrası: container'ların açılış satırları (bağlantı dizesi, servisin ayar satırları,
# Keycloak'ın realm içe aktarması ve yönetici hesabını oluşturması) onun dışında. Aynı aramalar şu anki container'ların
# açılışından bu yana bütün loglarda (önceki container kopyalarının logu docker'da kalmaz).
$allFile = Join-Path $OutputDir "$reportName-acilistan-loglar.txt"
[IO.File]::WriteAllLines($allFile, $all, [Text.UTF8Encoding]::new($true))
$allServices = @($all | ForEach-Object { if ($_ -match '^(\S+?)-\d+\s+\|') { $Matches[1] } } | Sort-Object -Unique)
Write-Line ''
Write-Line "Şu anki container'ların açılışından bu yana bütün loglar: $($all.Count) satır, $($allServices.Count) container; tamamı $(Split-Path $allFile -Leaf)"
foreach ($name in $searches.Keys) {
    $hits = @($all | Where-Object { $_ -match $searches[$name] })
    Check ($hits.Count -eq 0) ("{0,-48} {1}" -f $name, $hits.Count)
    foreach ($hit in ($hits | Select-Object -First 3)) { Write-Line "      $($hit.Substring(0, [Math]::Min(200, $hit.Length)))" }
}
$startup = @($all | Where-Object { $_ -match 'settings:|Now listening|Imported realm|Realm .* imported|Added user|admin user|created temporary admin' })
Write-Line "  (açılış satırlarından örnek: bulunan $($startup.Count) satır; ilk 3)"
foreach ($line in ($startup | Select-Object -First 3)) { Write-Line "      $($line.Substring(0, [Math]::Min(200, $line.Length)))" }

Save-Report
Write-Result $script:AllPassed 'Loglarda token, şifre ve secret bulunmadı.'
