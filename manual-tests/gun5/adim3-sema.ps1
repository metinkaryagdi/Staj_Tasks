# Gün 5 - Adım 3: veritabanı şeması (kontrol listesinin parçası değil, adımın kendi testi). ~1 dk.
# Fatura Servisi yeni kodla yeniden derlenir; açılışta AddReconciliation migration'ı uygulanır. Sonra:
#   - reconciliation_runs (8 kolon) ve reconciliation_findings (7 kolon) görevde istenen kolonlarla var; ek kolon yok
#   - durumlar, tutarlılık kuralları ve bulgu türü / eylem eşleşmesi veritabanı kısıtlarıyla korunuyor
#   - erp_webhook_events.ignore_reason artık "Fatura Yok" kabul ediyor
# Kısıt denemeleri BEGIN ... ROLLBACK içinde yapılır, veritabanında iz bırakmaz.
. "$PSScriptRoot\_common.ps1"

Write-Title 'Adım 3) Veritabanı: reconciliation_runs, reconciliation_findings, ignore_reason = Fatura Yok'

Write-Step 'Fatura Servisi yeni kodla derlenip yeniden başlatılıyor (migration açılışta uygulanır)...'
Invoke-Compose @('up', '-d', '--build', 'invoice-service')
Wait-Service
Write-Host '  Fatura Servisi ayakta.'

$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Write-DbHeader 'Uygulanan migration''lar' ''
$migrations = @(Invoke-ServiceSqlStdin 'SELECT "MigrationId" FROM "__EFMigrationsHistory" ORDER BY 1;' -Rows)
$migrations | ForEach-Object { Write-Host "  $_" }
Check (Write-DbVerdict 'AddReconciliation uygulanmış' ($migrations[-1]) ($migrations[-1] -match '_AddReconciliation$'))

Write-DbHeader 'Kolonlar' 'Görevde istenen kolonlar; ek kolon yok'
foreach ($table in 'reconciliation_runs', 'reconciliation_findings') {
    Show-ServiceQuery "SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_name = '$table' ORDER BY ordinal_position;"
}
$runs = (@(Get-ServiceRows "SELECT column_name FROM information_schema.columns WHERE table_name = 'reconciliation_runs' ORDER BY ordinal_position;") -join ',')
$findings = (@(Get-ServiceRows "SELECT column_name FROM information_schema.columns WHERE table_name = 'reconciliation_findings' ORDER BY ordinal_position;") -join ',')
Check (Write-DbVerdict 'id,started_at,finished_at,status,checked_count,fixed_count,reported_count,error' $runs `
    ($runs -eq 'id,started_at,finished_at,status,checked_count,fixed_count,reported_count,error'))
Check (Write-DbVerdict 'id,run_id,invoice_number,finding_type,action,details,created_at' $findings `
    ($findings -eq 'id,run_id,invoice_number,finding_type,action,details,created_at'))

Write-DbHeader 'Kısıtlar' ''
Show-ServiceQuery ("SELECT conrelid::regclass AS tablo, conname AS kisit, pg_get_constraintdef(oid) AS tanim FROM pg_constraint " +
    "WHERE conrelid IN ('reconciliation_runs'::regclass, 'reconciliation_findings'::regclass) ORDER BY 1, 2;")
Show-ServiceQuery "SELECT pg_get_constraintdef(oid) AS ignore_reason_kisiti FROM pg_constraint WHERE conname = 'ck_erp_webhook_events_ignore_reason';"

Write-DbHeader 'Kısıtlar gerçekten çalışıyor mu' 'Her satır BEGIN ... ROLLBACK içinde denenir'
$run = "INSERT INTO reconciliation_runs (started_at, finished_at, status, checked_count, fixed_count, reported_count, error) " +
       "VALUES (now(), {0}, '{1}', {2}, 0, 0, {3});"
$finding = "WITH r AS (INSERT INTO reconciliation_runs (started_at, status, checked_count, fixed_count, reported_count) " +
           "VALUES (now(), 'Çalışıyor', 0, 0, 0) RETURNING id) " +
           "INSERT INTO reconciliation_findings (run_id, invoice_number, finding_type, action, details, created_at) " +
           "SELECT id, 'ADIM3-TEST', '{0}', '{1}', 'deneme', now() FROM r;"
$event = "INSERT INTO erp_webhook_events (event_id, event_type, invoice_number, erp_reference, occurred_at, received_at, status, ignore_reason, payload) " +
         "VALUES ('ADIM3-E', 'invoice.received', 'ADIM3-YOK', 'ERP-1', now(), now(), 'Yok Sayıldı', {0}, '{{}}');"
$before = [int]@(Get-ServiceRows "SELECT (SELECT count(*) FROM reconciliation_runs) + (SELECT count(*) FROM reconciliation_findings) + (SELECT count(*) FROM erp_webhook_events WHERE event_id = 'ADIM3-E');")[0]
$cases = @(
    @{ Name = "run: Çalışıyor, finished_at boş";                 Accept = $true;  Sql = ($run -f 'NULL', 'Çalışıyor', 0, 'NULL') }
    @{ Name = "run: Çalışıyor ama finished_at dolu";             Accept = $false; Sql = ($run -f 'now()', 'Çalışıyor', 0, 'NULL') }
    @{ Name = "run: Tamamlandı, finished_at dolu";               Accept = $true;  Sql = ($run -f 'now()', 'Tamamlandı', 5, 'NULL') }
    @{ Name = "run: Tamamlandı ama finished_at boş";             Accept = $false; Sql = ($run -f 'NULL', 'Tamamlandı', 5, 'NULL') }
    @{ Name = "run: Başarısız, error dolu";                      Accept = $true;  Sql = ($run -f 'now()', 'Başarısız', 0, "'ERP yok'") }
    @{ Name = "run: Başarısız ama error boş";                    Accept = $false; Sql = ($run -f 'now()', 'Başarısız', 0, 'NULL') }
    @{ Name = "run: Tamamlandı ama error dolu";                  Accept = $false; Sql = ($run -f 'now()', 'Tamamlandı', 0, "'x'") }
    @{ Name = "run: tanımsız durum";                             Accept = $false; Sql = ($run -f 'now()', 'Bitti', 0, 'NULL') }
    @{ Name = "run: negatif sayaç";                              Accept = $false; Sql = ($run -f 'now()', 'Tamamlandı', -1, 'NULL') }
    @{ Name = "bulgu: Takılı Fatura + Düzeltildi";               Accept = $true;  Sql = ($finding -f 'Takılı Fatura', 'Düzeltildi') }
    @{ Name = "bulgu: Serviste Yok + Raporlandı";                Accept = $true;  Sql = ($finding -f 'Serviste Yok', 'Raporlandı') }
    @{ Name = "bulgu: Serviste Yok + Düzeltildi";                Accept = $false; Sql = ($finding -f 'Serviste Yok', 'Düzeltildi') }
    @{ Name = "bulgu: Takılı Fatura + Raporlandı";               Accept = $false; Sql = ($finding -f 'Takılı Fatura', 'Raporlandı') }
    @{ Name = "bulgu: tanımsız tür";                             Accept = $false; Sql = ($finding -f 'Başka', 'Raporlandı') }
    @{ Name = "bulgu: olmayan çalışma";                          Accept = $false
       Sql = "INSERT INTO reconciliation_findings (run_id, invoice_number, finding_type, action, details, created_at) VALUES (-1, 'X', 'Alan Farkı', 'Raporlandı', 'x', now());" }
    @{ Name = "haber: Yok Sayıldı + Fatura Yok";                 Accept = $true;  Sql = ($event -f "'Fatura Yok'") }
    @{ Name = "haber: Yok Sayıldı + tanımsız neden";             Accept = $false; Sql = ($event -f "'Bilinmeyen'") }
    @{ Name = "haber: Yok Sayıldı ama neden boş";                Accept = $false; Sql = ($event -f 'NULL') }
)
foreach ($case in $cases) {
    Write-Host ''
    Write-Host "  $($case.Name)" -ForegroundColor Yellow
    $r = Test-ServiceSql $case.Sql
    $actual = if ($r.Accepted) { 'kabul edildi' } else { "reddedildi ($($r.Error))" }
    Check (Write-DbVerdict $(if ($case.Accept) { 'kabul edilir' } else { 'reddedilir' }) $actual ($r.Accepted -eq $case.Accept))
}
$after = [int]@(Get-ServiceRows "SELECT (SELECT count(*) FROM reconciliation_runs) + (SELECT count(*) FROM reconciliation_findings) + (SELECT count(*) FROM erp_webhook_events WHERE event_id = 'ADIM3-E');")[0]
Write-Host ''
Check (Write-DbVerdict 'denemelerden geriye kayıt kalmadı' "$before -> $after kayıt" ($after -eq $before))

Write-Result $allPassed 'şema hazır: iki tablo, durum ve tür kısıtları, ignore_reason = Fatura Yok'
