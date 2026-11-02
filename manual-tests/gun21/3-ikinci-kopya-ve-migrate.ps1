# O9'un iki yolu: (1) iki-kopya profilindeki invoice-service-2 de invoice_app ile bağlanıyor ve fatura gönderebiliyor;
# (2) compose dışında `dotnet run -- --migrate-only` migration'ları uygulayıp uygulama kullanıcısını oluşturuyor. (2) boş bir
# deneme veritabanında ve ayrı adlı bir kullanıcıyla yapılır (invoice_app'in şifresi sunucu genelindedir, değişmesin); ikisi de
# sonunda silinir. Çıktı manual-tests\output\gun21\<-Etiket>.txt. ~3 dk.
#   .\manual-tests\gun21\3-ikinci-kopya-ve-migrate.ps1
param([string]$Etiket = 'c-ikinci-kopya-ve-migrate')
. "$PSScriptRoot\_common.ps1"

New-Report $Etiket
Write-Title 'O9: ikinci kopya ve compose dışında migrate'
Start-Stack
Write-Line "Koşu: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
function Get-Field([string]$Body, [string]$Name) { try { ($Body | ConvertFrom-Json).$Name } catch { $null } }

Write-Line ''
Write-Line '1) invoice-service-2 (iki-kopya profili, 127.0.0.1:5091)'
Push-Location $RepoRoot
try { docker compose --profile iki-kopya up -d --build invoice-service-2 2>&1 | Out-Null } finally { Pop-Location }
$deadline = (Get-Date).AddMinutes(2)
do { $health = Send-Http GET 'http://localhost:5091/health'; if ($health.Status -ne 200) { Start-Sleep -Seconds 2 } } while ($health.Status -ne 200 -and (Get-Date) -lt $deadline)
Check ($health.Status -eq 200) "GET :5091/health: HTTP $($health.Status)"
$cred = Get-AppDbUser 'invoice-service-2' 'ConnectionStrings__InvoiceDb'
Check ($cred.User -eq 'invoice_app') "Bağlantı dizesindeki kullanıcı: $($cred.User)"
$role = Invoke-Psql 'invoice-db' $cred.User $cred.Password 'invoice_service' 'SELECT rolsuper FROM pg_roles WHERE rolname = current_user'
Check ($role.Text -eq 'f') "Bu kullanıcıyla rolsuper: $($role.Text)"
$order = Get-OrderSystemToken
$created = Send-Http POST 'http://localhost:5091/api/v1/invoices' @{ Authorization = "Bearer $order" } '{"customerCode":"GUN21-IKINCI-KOPYA","amount":10.5,"currency":"TRY","invoiceDate":"2026-11-02"}'
$number = (Get-Field $created.Body 'invoiceNumber')
Check ($created.Status -eq 202) "POST :5091/api/v1/invoices: HTTP $($created.Status), $number"
$deadline = (Get-Date).AddMinutes(2)
do {
    $status = @(Get-ServiceRows "SELECT o.status FROM erp_outbox o WHERE o.invoice_number = '$number';")[0]
    if ($status -eq 'Bekliyor') { Start-Sleep -Seconds 3 }
} while ($status -eq 'Bekliyor' -and (Get-Date) -lt $deadline)
$erp = @(Get-ErpRows "SELECT count(*) FROM invoices WHERE invoice_number = '$number' AND customer_code = 'GUN21-IKINCI-KOPYA';")[0]
Check ($status -eq 'Tamamlandı' -and $erp -eq '1') "Gönderim: outbox $status, ERP'de kayıt $erp"
$errors = @(Push-Location $RepoRoot; docker compose logs invoice-service-2 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'permission denied|42501' }; Pop-Location)
Check ($errors.Count -eq 0) "invoice-service-2 logunda yetki hatası (permission denied / 42501): $($errors.Count)"
Push-Location $RepoRoot
try { docker compose --profile iki-kopya stop invoice-service-2 2>&1 | Out-Null } finally { Pop-Location }

Write-Line ''
Write-Line '2) Compose dışında: dotnet run --project invoice-service/src/InvoiceService.Api -- --migrate-only'
$ownerPassword = Get-DotEnvValue 'INVOICE_DB_PASSWORD'
[void](Invoke-Psql 'invoice-db' 'invoice' $ownerPassword 'invoice_service' 'DROP DATABASE IF EXISTS gun21_migrate_denemesi')
[void](Invoke-Psql 'invoice-db' 'invoice' $ownerPassword 'invoice_service' 'DROP ROLE IF EXISTS gun21_deneme_app')
[void](Invoke-Psql 'invoice-db' 'invoice' $ownerPassword 'invoice_service' 'CREATE DATABASE gun21_migrate_denemesi')
$appPassword = -join ((1..32) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
$env:ConnectionStrings__InvoiceDb = "Host=localhost;Port=5434;Database=gun21_migrate_denemesi;Username=invoice;Password=$ownerPassword"
$env:AppDatabaseUser__Name = 'gun21_deneme_app'
$env:AppDatabaseUser__Password = $appPassword
try {
    $run = @(& dotnet run --project (Join-Path $RepoRoot 'invoice-service\src\InvoiceService.Api') -- --migrate-only 2>&1 | ForEach-Object { "$_" })
    $exit = $LASTEXITCODE
}
finally { Remove-Item Env:ConnectionStrings__InvoiceDb, Env:AppDatabaseUser__Name, Env:AppDatabaseUser__Password }
$granted = @($run | Where-Object { $_ -match 'Application user' }) | Select-Object -Last 1
Check ($exit -eq 0) "Çıkış kodu $exit; $($granted -replace '^.*(Application user)', '$1')"
$tables = Invoke-Psql 'invoice-db' 'invoice' $ownerPassword 'gun21_migrate_denemesi' "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'"
Check ([int]$tables.Text -gt 0) "Deneme veritabanında tablo sayısı: $($tables.Text)"
$super = Invoke-Psql 'invoice-db' 'gun21_deneme_app' $appPassword 'gun21_migrate_denemesi' 'SELECT rolsuper FROM pg_roles WHERE rolname = current_user'
Check ($super.Text -eq 'f') "gun21_deneme_app ile bağlantı, rolsuper: $($super.Text)"
$drop = Invoke-Psql 'invoice-db' 'gun21_deneme_app' $appPassword 'gun21_migrate_denemesi' 'BEGIN; DROP TABLE invoices CASCADE; ROLLBACK;'
Check (-not $drop.Ok) "gun21_deneme_app ile DROP TABLE invoices: $($drop.Text)"
[void](Invoke-Psql 'invoice-db' 'invoice' $ownerPassword 'invoice_service' 'DROP DATABASE gun21_migrate_denemesi WITH (FORCE)')
$cleanup = Invoke-Psql 'invoice-db' 'invoice' $ownerPassword 'invoice_service' 'DROP ROLE gun21_deneme_app'
Write-Line "  Deneme veritabanı ve kullanıcısı silindi: $(if ($cleanup.Ok) { 'evet' } else { $cleanup.Text })"

Write-Line ''
Write-Line "Sonuç: $(if ($script:AllPassed) { 'bütün kontroller TAMAM' } else { 'FARKLI satırlar var' })"
Save-Report
