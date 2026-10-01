# Gün 3 - Adım 1: veritabanı şeması (kontrol listesinin parçası değil, adımın kendi testi).
# Fatura Servisi yeni kodla yeniden derlenir; açılışta AddErpOutbox migration'ı uygulanır. Sonra:
#   - invoices.status artık Bekliyor / Gönderildi / Başarısız kabul ediyor, başka bir değeri reddediyor
#   - erp_outbox tablosu istenen 8 kolon + eklenen 2 kolonla (locked_until, locked_by) var
#   - erp_outbox.status yalnızca Bekliyor / Tamamlandı / Başarısız; bir fatura için tek kayıt; olmayan fatura için kayıt yok
#   - Bu adımda davranış değişmedi: POST hâlâ simülatöre doğrudan gidiyor, erp_outbox'a hiçbir şey yazılmıyor
# Kısıt denemeleri BEGIN ... ROLLBACK içinde yapılır, veritabanında iz bırakmaz.
. "$PSScriptRoot\_common.ps1"

Write-Title 'Adım 1) Veritabanı: invoices.status üç değer, yeni erp_outbox tablosu'

Write-Step 'Fatura Servisi yeni kodla derlenip yeniden başlatılıyor (migration açılışta uygulanır)...'
Invoke-Compose @('up', '-d', '--build', 'invoice-service')
Wait-Service
Write-Host '  Fatura Servisi ayakta.'

$allPassed = $true

Write-DbHeader 'Uygulanan migration''lar' ''
$migrationSql = 'SELECT "MigrationId", "ProductVersion" FROM "__EFMigrationsHistory" ORDER BY 1;'
Write-Host ''
Write-Host "Fatura Servisi (invoice-db) SQL: $migrationSql" -ForegroundColor DarkGray
Invoke-ServiceSqlStdin $migrationSql | Out-Host
$migrations = @(Invoke-ServiceSqlStdin 'SELECT "MigrationId" FROM "__EFMigrationsHistory" ORDER BY 1;' -Rows)
$ok = Write-DbVerdict 'InitialCreate ve AddErpOutbox uygulanmış' ($migrations -join ', ') `
    (@($migrations | Where-Object { $_ -match '_InitialCreate$|_AddErpOutbox$' }).Count -eq 2)
$allPassed = $allPassed -and $ok

Write-DbHeader 'erp_outbox kolonları' 'İlk 8 kolon görevde istenenler; locked_until ve locked_by eklenenler'
Show-ServiceQuery ("SELECT column_name, data_type, is_nullable FROM information_schema.columns " +
    "WHERE table_name = 'erp_outbox' ORDER BY ordinal_position;")
$expectedColumns = 'id,invoice_number,status,attempt_count,next_attempt_at,last_error,created_at,processed_at,locked_until,locked_by'
$columns = (@(Get-ServiceRows "SELECT column_name FROM information_schema.columns WHERE table_name = 'erp_outbox' ORDER BY ordinal_position;") -join ',')
$ok = Write-DbVerdict $expectedColumns $columns ($columns -eq $expectedColumns)
$allPassed = $allPassed -and $ok

Write-DbHeader 'Kısıtlar ve index''ler' ''
Show-ServiceQuery ("SELECT conrelid::regclass AS tablo, conname AS kisit, pg_get_constraintdef(oid) AS tanim FROM pg_constraint " +
    "WHERE conrelid IN ('invoices'::regclass, 'erp_outbox'::regclass) ORDER BY 1, 2;")
Show-ServiceQuery "SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'erp_outbox' ORDER BY 1;"

Write-DbHeader 'Kısıtlar gerçekten çalışıyor mu' 'Her satır BEGIN ... ROLLBACK içinde denenir'
$invoiceInsert = "INSERT INTO invoices (invoice_number, customer_code, amount, currency, invoice_date, status, send_attempt_count, created_at, updated_at) " +
    "VALUES ('ADIM1-TEST', 'C-001', 10, 'TRY', '2026-10-01', '{0}', 0, now(), now());"
$outboxInsert = "INSERT INTO erp_outbox (invoice_number, status, attempt_count, next_attempt_at, created_at) VALUES ('{0}', '{1}', 0, now(), now());"
$cases = @(
    @{ Name = "invoices.status = 'Bekliyor'";   Accept = $true;  Sql = ($invoiceInsert -f 'Bekliyor') }
    @{ Name = "invoices.status = 'Tamamlandı'"; Accept = $false; Sql = ($invoiceInsert -f 'Tamamlandı') }
    @{ Name = "erp_outbox.status = 'Bekliyor'"; Accept = $true;  Sql = ($invoiceInsert -f 'Bekliyor') + ($outboxInsert -f 'ADIM1-TEST', 'Bekliyor') }
    @{ Name = "erp_outbox.status = 'Gönderildi'"; Accept = $false; Sql = ($invoiceInsert -f 'Bekliyor') + ($outboxInsert -f 'ADIM1-TEST', 'Gönderildi') }
    @{ Name = 'aynı fatura için ikinci erp_outbox kaydı'; Accept = $false
       Sql = ($invoiceInsert -f 'Bekliyor') + ($outboxInsert -f 'ADIM1-TEST', 'Bekliyor') + ($outboxInsert -f 'ADIM1-TEST', 'Bekliyor') }
    @{ Name = 'olmayan fatura için erp_outbox kaydı'; Accept = $false; Sql = ($outboxInsert -f 'YOK-000000', 'Bekliyor') }
)
foreach ($case in $cases) {
    Write-Host ''
    Write-Host "  $($case.Name)" -ForegroundColor Yellow
    $r = Test-ServiceSql $case.Sql
    $actual = if ($r.Accepted) { 'kabul edildi' } else { "reddedildi ($($r.Error))" }
    $ok = Write-DbVerdict $(if ($case.Accept) { 'kabul edilir' } else { 'reddedilir' }) $actual ($r.Accepted -eq $case.Accept)
    $allPassed = $allPassed -and $ok
}
$leftover = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE invoice_number = 'ADIM1-TEST';")[0]
Write-Host ''
$ok = Write-DbVerdict 'denemelerden geriye kayıt kalmadı' "$leftover kayıt" ($leftover -eq 0)
$allPassed = $allPassed -and $ok

Write-Step 'Bu adımda davranış değişmedi: bir fatura oluşturuluyor (hâlâ doğrudan simülatöre gider)'
$outboxBefore = [int]@(Get-ServiceRows 'SELECT count(*) FROM erp_outbox;')[0]
$r = New-ServiceInvoice
Write-ServiceResult $r
$outboxAfter = [int]@(Get-ServiceRows 'SELECT count(*) FROM erp_outbox;')[0]

Write-DbHeader 'Yeni fatura' "Fatura numarası: $($r.InvoiceNumber)"
Show-ServiceQuery "SELECT invoice_number, status, erp_reference, send_attempt_count FROM invoices WHERE invoice_number = '$($r.InvoiceNumber)';"
Show-ServiceQuery 'SELECT count(*) AS outbox_kayit FROM erp_outbox;'
$ok = Write-DbVerdict '201 (Gün 2 davranışı), erp_outbox boş kaldı' "$($r.HttpStatus), erp_outbox $outboxBefore -> $outboxAfter kayıt" `
    ($r.HttpStatus -eq 201 -and $outboxAfter -eq $outboxBefore)
$allPassed = $allPassed -and $ok

Write-Result $allPassed 'şema hazır: invoices.status üç değer, erp_outbox 10 kolon ve kısıtlarıyla; davranış henüz değişmedi'
