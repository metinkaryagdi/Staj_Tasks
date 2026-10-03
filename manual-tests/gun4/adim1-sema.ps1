# Gün 4 - Adım 1: Fatura Servisi şeması. Uygulamaya yeni davranış eklenmedi; yalnızca tablolar. ~1 dk.
#
#   A) Migration uygulandı: invoices.reject_reason var, erp_webhook_events tablosu görevin 9 kolonu + delivery_count ve
#      ignore_reason (Adım 3'te eklendi) ile var.
#   B) invoices.status yeni değerleri kabul ediyor (İşleme Alındı, Onaylandı, Reddedildi), bilinmeyen değeri reddediyor.
#   C) erp_webhook_events kısıtları: aynı event_id ikinci kez eklenemiyor; bilinmeyen event_type, bilinmeyen status ve
#      delivery_count = 0 reddediliyor.
#   D) Tekrar gelen haberin nasıl sayılacağı: aynı event_id ile INSERT ... ON CONFLICT -> satır sayısı 1 kalıyor,
#      delivery_count 2 oluyor; ilk istek "eklendi", ikincisi "zaten vardı" görüyor.
#
# B, C ve D'deki bütün yazmalar BEGIN ... ROLLBACK içinde: veritabanında iz bırakmaz.
# Önce servisin yeni kodla derlenmiş olması gerekir (migration açılışta uygulanır): docker compose up -d --build
. "$PSScriptRoot\_common.ps1"

Write-Title 'Adım 1) Fatura Servisi şeması: 6 durum, reject_reason, erp_webhook_events'
Wait-Service
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

# --- A) Migration ---------------------------------------------------------------------------------------------------
Write-DbHeader 'A) Migration' 'Son migration ve yeni kolonlar'
# Adım 3'ün migration'ı uygulanmış olmalı; ondan sonra eklenenler (ör. ProcessedAtOnlyWhenApplied) de olabilir.
$applied = @(Invoke-ServiceSqlStdin 'SELECT "MigrationId" FROM "__EFMigrationsHistory" ORDER BY "MigrationId";' -Rows)
$step3 = @($applied | Where-Object { $_ -like '*_AddWebhookIgnoreReason' })
Check (Write-DbVerdict '*_AddWebhookIgnoreReason (Adım 3) uygulanmış' ($applied -join ', ') ($step3.Count -eq 1))

$sql = "SELECT column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_name = 'erp_webhook_events' ORDER BY ordinal_position;"
Show-ServiceQuery $sql
$columns = @(Get-ServiceRows "SELECT column_name FROM information_schema.columns WHERE table_name = 'erp_webhook_events' ORDER BY ordinal_position;")
$expected = 'event_id,event_type,invoice_number,erp_reference,occurred_at,received_at,processed_at,status,payload,delivery_count,ignore_reason'
Check (Write-DbVerdict $expected ($columns -join ',') (($columns -join ',') -eq $expected))

$reject = @(Get-ServiceRows "SELECT data_type || ' ' || is_nullable FROM information_schema.columns WHERE table_name = 'invoices' AND column_name = 'reject_reason';")
Check (Write-DbVerdict 'invoices.reject_reason: text YES (boş olabilir)' "invoices.reject_reason: $($reject -join '')" (($reject -join '') -eq 'text YES'))

Show-ServiceQuery "SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid IN ('invoices'::regclass, 'erp_webhook_events'::regclass) AND contype IN ('c', 'p') ORDER BY conname;"

Show-ServiceQuery 'SELECT status, count(*) FROM invoices GROUP BY status ORDER BY status;'
Write-Host '  Mevcut faturalar migration sonrasında değişmedi (yalnızca eski durumlar var).' -ForegroundColor DarkGray

# --- B) invoices.status ---------------------------------------------------------------------------------------------
Write-DbHeader 'B) invoices.status' 'Her deneme ayrı bir transaction içinde, sonunda geri alınır'
$invoice = @(Get-ServiceRows 'SELECT invoice_number FROM invoices ORDER BY invoice_number DESC LIMIT 1;')[0]
foreach ($case in @(
        @{ Value = 'İşleme Alındı'; Accept = $true }, @{ Value = 'Onaylandı'; Accept = $true },
        @{ Value = 'Reddedildi'; Accept = $true }, @{ Value = 'Bilinmiyor'; Accept = $false })) {
    $r = Test-ServiceSql "UPDATE invoices SET status = '$($case.Value)' WHERE invoice_number = '$invoice';"
    $text = if ($r.Accepted) { 'kabul' } else { "red ($($r.Error))" }
    Check (Write-DbVerdict "status = '$($case.Value)' -> $(if ($case.Accept) { 'kabul' } else { 'red' })" $text ($r.Accepted -eq $case.Accept))
}

# --- C) erp_webhook_events kısıtları -------------------------------------------------------------------------------
Write-DbHeader 'C) erp_webhook_events kısıtları' 'Her deneme ayrı bir transaction içinde, sonunda geri alınır'
function EventInsert([string]$Id, [string]$Type = 'invoice.received', [string]$Status = 'Bekliyor', [string]$Count = '1') {
    "INSERT INTO erp_webhook_events (event_id, event_type, invoice_number, erp_reference, occurred_at, received_at, status, payload, delivery_count) " +
    "VALUES ('$Id', '$Type', 'FTR-999999', 'ERP-TEST', now(), now(), '$Status', '{}', $Count);"
}
foreach ($case in @(
        @{ Name = 'geçerli haber'; Sql = (EventInsert 'sema-test-1'); Accept = $true },
        @{ Name = 'aynı event_id iki kez'; Sql = (EventInsert 'sema-test-1') + ' ' + (EventInsert 'sema-test-1'); Accept = $false },
        @{ Name = "event_type = 'invoice.paid'"; Sql = (EventInsert 'sema-test-2' -Type 'invoice.paid'); Accept = $false },
        @{ Name = "status = 'Silindi'"; Sql = (EventInsert 'sema-test-3' -Status 'Silindi'); Accept = $false },
        @{ Name = 'delivery_count = 0'; Sql = (EventInsert 'sema-test-4' -Count '0'); Accept = $false })) {
    $r = Test-ServiceSql $case.Sql
    $text = if ($r.Accepted) { 'kabul' } else { "red ($($r.Error))" }
    Check (Write-DbVerdict "$($case.Name) -> $(if ($case.Accept) { 'kabul' } else { 'red' })" $text ($r.Accepted -eq $case.Accept))
}

# --- D) Tekrar sayımı -----------------------------------------------------------------------------------------------
Write-DbHeader 'D) Tekrar gelen haber' 'Aynı event_id iki kez INSERT ... ON CONFLICT; sonunda geri alınır'
$upsert = (EventInsert 'sema-test-tekrar').TrimEnd(';') +
    ' ON CONFLICT (event_id) DO UPDATE SET delivery_count = erp_webhook_events.delivery_count + 1 RETURNING (xmax = 0) AS eklendi;'
$rows = @(Invoke-ServiceSqlStdin ("BEGIN; $upsert $upsert SELECT count(*) || '|' || max(delivery_count) FROM erp_webhook_events WHERE event_id = 'sema-test-tekrar'; ROLLBACK;") -Rows |
    Where-Object { $_ -notin @('BEGIN', 'ROLLBACK', 'INSERT 0 1') })
Write-Host "  SQL (iki kez): $upsert" -ForegroundColor DarkGray
Write-Host "  1. istek eklendi mi: $($rows[0])   2. istek eklendi mi: $($rows[1])   satır|delivery_count: $($rows[2])"
Check (Write-DbVerdict '1. istek t, 2. istek f; satır=1 delivery_count=2' "$($rows[0]), $($rows[1]); satır=$(($rows[2] -split '\|')[0]) delivery_count=$(($rows[2] -split '\|')[1])" `
    ($rows[0] -eq 't' -and $rows[1] -eq 'f' -and $rows[2] -eq '1|2'))

$left = @(Get-ServiceRows "SELECT count(*) FROM erp_webhook_events WHERE event_id LIKE 'sema-test-%';")[0]
Check (Write-DbVerdict 'bu script''in deneme satırları (sema-test-*) tabloda yok (hepsi geri alındı)' $left ($left -eq '0'))

Write-Result $allPassed 'şema görevdeki gibi; kısıtlar yanlış veriyi reddediyor, tekrar gelen haber satır eklemeden sayılıyor'
