# Bugünün migration'ları dünkü verinin üzerinde: Gün 21 koşularının veritabanı volume'lerinin bir kopyası ayrı PostgreSQL
# container'larında açılır (127.0.0.1:55432 ve 55433), migration'lar `dotnet ef database update` ile uygulanır, önce ve sonra
# satırlar sayılır. Gün 21 volume'lerine ve çalışan yığına dokunulmaz; kopyalar sonunda silinir. ~3 dk.
#   .\manual-tests\gun22\4-migration-dunku-veri.ps1
param([string]$Etiket = 'e-migration-dunku-veri')
. "$PSScriptRoot\_common.ps1"

New-Report $Etiket
Write-Title 'Migration: dünkü verinin üzerinde'
Write-Line "Koşu: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

function Invoke-Docker([string[]]$Arguments) {
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & docker @Arguments 2>&1 | Out-Null } finally { $ErrorActionPreference = $previous }
}

# Volume'ün kopyasıyla bir PostgreSQL açar; psql'i o container'da çalıştıran bir scriptblock döner.
function Open-Copy([string]$Source, [string]$Name, [int]$Port) {
    Invoke-Docker @('rm', '-f', $Name)
    Invoke-Docker @('volume', 'rm', "$Name-data")
    Invoke-Docker @('volume', 'create', "$Name-data")
    Invoke-Docker @('run', '--rm', '-v', "${Source}:/from:ro", '-v', "$Name-data:/to", 'postgres:17-alpine', 'sh', '-c', 'cp -a /from/. /to/')
    Invoke-Docker @('run', '-d', '--name', $Name, '-p', "127.0.0.1:${Port}:5432", '-v', "$Name-data:/var/lib/postgresql/data", 'postgres:17-alpine')
    for ($i = 0; $i -lt 60; $i++) {
        $ready = & docker exec $Name pg_isready 2>$null
        if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep -Seconds 1
    }
    Write-Line "  $Source kopyalandı, $Name açıldı (127.0.0.1:$Port)"
}
function Query([string]$Name, [string]$User, [string]$Database, [string]$Sql) {
    ((& docker exec $Name psql -U $User -d $Database -tAc $Sql 2>&1) | Out-String).Trim()
}
function Update-Database([string]$Project, [string]$Startup, [string]$Connection) {
    Push-Location $RepoRoot
    try { $out = & dotnet ef database update -p $Project -s $Startup --connection $Connection 2>&1 | ForEach-Object { "$_" } }
    finally { Pop-Location }
    $failed = @($out | Where-Object { $_ -match '(?i)error|exception' })
    [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0 -and $failed.Count -eq 0); Error = ($failed | Select-Object -First 3) -join ' | ' }
}

# ---------------------------------------------------------------------------------------------------------------------
Write-Line ''
Write-Line 'Fatura Servisi (staj-tasks_invoice-db-data-gun21)'
$inv = 'gun22-migtest-invoice'
Open-Copy 'staj-tasks_invoice-db-data-gun21' $inv 55432
$sql = { param($s) Query $inv 'invoice' 'invoice_service' $s }
# Windows PowerShell 5.1 native komutlara giden argümandaki çift tırnağı siler; \" ile kaçırılır.
$history = 'SELECT string_agg(\"MigrationId\", '', '' ORDER BY \"MigrationId\") FROM \"__EFMigrationsHistory\"'
$last = 'SELECT max(\"MigrationId\") FROM \"__EFMigrationsHistory\"'
$beforeLast = & $sql $last
Write-Line "  Önce: son migration $beforeLast"
$beforeRows = & $sql "SELECT count(*) || ' fatura, ' || (SELECT count(*) FROM erp_outbox) || ' outbox satırı, ' || (SELECT count(*) FROM operator_actions) || ' müdahale' FROM invoices"
Write-Line "  Önce: $beforeRows"
$beforeStatus = & $sql "SELECT string_agg(status || ' ' || n, ', ' ORDER BY status) FROM (SELECT status, count(*) n FROM erp_outbox GROUP BY status) s"
Write-Line "  Önce, outbox durumları: $beforeStatus"

$result = Update-Database 'invoice-service/src/InvoiceService.Infrastructure' 'invoice-service/src/InvoiceService.Api' `
    "Host=127.0.0.1;Port=55432;Database=invoice_service;Username=invoice;Password=$(Get-DotEnvValue 'INVOICE_DB_PASSWORD')"
$applied = (& $sql $history) -split ', ' | Where-Object { $_ -gt $beforeLast }
Check ($result.Ok -and $applied.Count -gt 0) "dotnet ef database update: uygulanan migration $($applied -join ', ') $($result.Error)"
$afterRows = & $sql "SELECT count(*) || ' fatura, ' || (SELECT count(*) FROM erp_outbox) || ' outbox satırı, ' || (SELECT count(*) FROM operator_actions) || ' müdahale' FROM invoices"
Check ($afterRows -eq $beforeRows) "Sonra: $afterRows"
$kinds = & $sql "SELECT string_agg(kind || ' ' || n, ', ') FROM (SELECT kind, count(*) n FROM erp_outbox GROUP BY kind) s"
$outboxCount = & $sql 'SELECT count(*) FROM erp_outbox'
Check ($kinds -eq "Gönderim $outboxCount") "Sonra, outbox satırlarının türü: $kinds"
$afterStatus = & $sql "SELECT string_agg(status || ' ' || n, ', ' ORDER BY status) FROM (SELECT status, count(*) n FROM erp_outbox GROUP BY status) s"
Check ($afterStatus -eq $beforeStatus) "Sonra, outbox durumları: $afterStatus"
Write-Line "  İndeksler ve kısıtlar: $(& $sql "SELECT string_agg(indexname, ', ') FROM pg_indexes WHERE tablename = 'erp_outbox'"); $(& $sql "SELECT string_agg(conname, ', ') FROM pg_constraint WHERE conrelid = 'erp_outbox'::regclass AND contype = 'c'")"

# Mevcut bir faturaya iptal satırı eklenebiliyor, ikinci iptal ve ikinci gönderim satırı eklenemiyor; deneme geri alınır.
$number = & $sql "SELECT invoice_number FROM erp_outbox WHERE status = 'Tamamlandı' LIMIT 1"
$probe = & $sql (@"
BEGIN;
INSERT INTO erp_outbox (invoice_number, kind, status, attempt_count, next_attempt_at, created_at) VALUES ('$number', 'İptal', 'Bekliyor', 0, now(), now()) ON CONFLICT (invoice_number, kind) DO NOTHING;
INSERT INTO erp_outbox (invoice_number, kind, status, attempt_count, next_attempt_at, created_at) VALUES ('$number', 'İptal', 'Bekliyor', 0, now(), now()) ON CONFLICT (invoice_number, kind) DO NOTHING;
INSERT INTO erp_outbox (invoice_number, kind, status, attempt_count, next_attempt_at, created_at) VALUES ('$number', 'Gönderim', 'Bekliyor', 0, now(), now()) ON CONFLICT (invoice_number, kind) DO NOTHING;
SELECT string_agg(kind, ',' ORDER BY kind) FROM erp_outbox WHERE invoice_number = '$number';
ROLLBACK;
"@)
$kindsOfNumber = ($probe -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match 'Gönderim|İptal' }) -join ''
Check ($kindsOfNumber -eq 'Gönderim,İptal') "Mevcut $number'e iptal satırı eklendi, ikinci iptal ve ikinci gönderim eklenmedi: $kindsOfNumber"

# ---------------------------------------------------------------------------------------------------------------------
Write-Line ''
Write-Line 'ERP Simülatörü (staj-tasks_erp-db-data-gun21)'
$erp = 'gun22-migtest-erp'
Open-Copy 'staj-tasks_erp-db-data-gun21' $erp 55433
$esql = { param($s) Query $erp 'erp' 'erp_simulator' $s }
$beforeErpLast = & $esql $last
Write-Line "  Önce: son migration $beforeErpLast"
$beforeErp = & $esql "SELECT count(*) || ' kayıt, ' || (SELECT count(*) FROM webhook_deliveries) || ' webhook satırı' FROM invoices"
Write-Line "  Önce: $beforeErp"
$erpResult = Update-Database 'erp-simulator/src/ErpSimulator.Infrastructure' 'erp-simulator/src/ErpSimulator.Api' `
    "Host=127.0.0.1;Port=55433;Database=erp_simulator;Username=erp;Password=$(Get-DotEnvValue 'ERP_DB_PASSWORD')"
$erpApplied = (& $esql $history) -split ', ' | Where-Object { $_ -gt $beforeErpLast }
Check ($erpResult.Ok -and $erpApplied.Count -gt 0) "dotnet ef database update: uygulanan migration $($erpApplied -join ', ') $($erpResult.Error)"
$afterErp = & $esql "SELECT count(*) || ' kayıt, ' || (SELECT count(*) FROM webhook_deliveries) || ' webhook satırı' FROM invoices"
Check ($afterErp -eq $beforeErp) "Sonra: $afterErp; cancellations satırı: $(& $esql 'SELECT count(*) FROM cancellations')"

Invoke-Docker @('rm', '-f', $inv, $erp)
Invoke-Docker @('volume', 'rm', "$inv-data", "$erp-data")
Write-Line ''
Write-Line 'Kopya container''lar ve volume''ler silindi'
Save-Report
