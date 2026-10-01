# Gün 3 - Adım 2: POST faturayı ve erp_outbox kaydını aynı transaction'da yazıyor, 202 dönüyor, simülatöre gitmiyor.
# (Kontrol listesinin parçası değil, adımın kendi testi. Worker henüz yok: faturalar Bekliyor'da kalır.)
#
#   1) Simülatör açıkken 5 fatura: hepsi 202 + Bekliyor; her biri için tam bir erp_outbox kaydı (Bekliyor, 0 deneme);
#      simülatöre hiç istek gitmiyor (simülatör logunda ve erp-db'de bu faturalar yok).
#   2) Aynı transaction: erp_outbox'a yazmayı geçici bir trigger ile bozuyoruz. POST hata almalı ve fatura da
#      yazılmamalı (yarım kayıt yok). Trigger script sonunda her durumda kaldırılır.
. "$PSScriptRoot\_common.ps1"

Write-Title 'Adım 2) POST: fatura + erp_outbox aynı transaction''da, 202, simülatöre gitmiyor'

Write-Step 'Fatura Servisi yeni kodla derlenip yeniden başlatılıyor...'
Invoke-Compose @('up', '-d', '--build', 'invoice-service')
Wait-Service
Restart-Simulator
Write-Host '  İki uygulama da ayakta (simülatör açık: servis ona gitseydi logunda görünecekti).'

$allPassed = $true

# --- 1) 5 fatura ------------------------------------------------------------------------------------------------
Write-Step '5 fatura oluşturuluyor'
$results = @()
for ($i = 0; $i -lt 5; $i++) {
    $r = New-ServiceInvoice
    $results += $r
    Write-Host ('  {0,-12} -> {1} {2,-9} deneme={3}  süre={4}s' -f $r.InvoiceNumber, $r.HttpStatus, $r.Status, $r.Attempts, $r.Seconds)
}
$from = $results[0].InvoiceNumber
$to = $results[-1].InvoiceNumber
$httpOk = @($results | Where-Object { $_.HttpStatus -eq 202 -and $_.Status -eq 'Bekliyor' -and $_.Attempts -eq 0 }).Count
Write-Host ''
$ok = Write-DbVerdict '5 cevabın hepsi 202, status Bekliyor, deneme 0' "$httpOk/5" ($httpOk -eq 5)
$allPassed = $allPassed -and $ok

$range = "invoice_number BETWEEN '$from' AND '$to'"
Write-DbHeader 'Fatura ve outbox kayıtları' "Fatura aralığı: $from .. $to"
Show-ServiceQuery "SELECT invoice_number, status, erp_reference, last_error, send_attempt_count, created_at FROM invoices WHERE $range ORDER BY 1;"
Show-ServiceQuery ("SELECT id, invoice_number, status, attempt_count, next_attempt_at, last_error, created_at, processed_at, locked_until, locked_by " +
    "FROM erp_outbox WHERE $range ORDER BY id;")
Show-ErpQuery "SELECT count(*) AS kayit FROM invoices WHERE $range;"

$pairs = [int]@(Get-ServiceRows ("SELECT count(*) FROM invoices i JOIN erp_outbox o USING (invoice_number) WHERE i.$range " +
    "AND i.status = 'Bekliyor' AND o.status = 'Bekliyor' AND o.attempt_count = 0 AND o.next_attempt_at = o.created_at " +
    "AND o.processed_at IS NULL AND o.locked_until IS NULL AND o.last_error IS NULL AND i.created_at = o.created_at;"))[0]
$outboxRows = [int]@(Get-ServiceRows "SELECT count(*) FROM erp_outbox WHERE $range;")[0]
$erpRows = [int]@(Get-ErpRows "SELECT count(*) FROM invoices WHERE $range;")[0]
$logLines = @(Get-SimulatorLog | Where-Object { $_ -match 'invoice=(FTR-\d+)' -and $Matches[1] -ge $from -and $Matches[1] -le $to }).Count
Write-Host ''
$ok = Write-DbVerdict ('5 fatura Bekliyor, her birinin tam bir outbox kaydı var (Bekliyor, 0 deneme, hemen gönderilebilir, ' +
    'aynı created_at); simülatörde 0 kayıt, logunda 0 istek') `
    "$pairs fatura+outbox çifti, $outboxRows outbox kaydı; simülatörde $erpRows kayıt, logunda $logLines istek" `
    ($pairs -eq 5 -and $outboxRows -eq 5 -and $erpRows -eq 0 -and $logLines -eq 0)
$allPassed = $allPassed -and $ok

# --- 2) Aynı transaction -----------------------------------------------------------------------------------------
Write-Step 'erp_outbox''a yazma geçici bir trigger ile bozuluyor, sonra bir fatura daha oluşturuluyor'
$createTrigger = @'
CREATE FUNCTION adim2_outbox_bozuk() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'adim2 testi: erp_outbox yazilamadi'; END $$;
CREATE TRIGGER adim2_outbox_bozuk BEFORE INSERT ON erp_outbox FOR EACH ROW EXECUTE FUNCTION adim2_outbox_bozuk();
'@
$dropTrigger = 'SET client_min_messages = warning; DROP TRIGGER IF EXISTS adim2_outbox_bozuk ON erp_outbox; DROP FUNCTION IF EXISTS adim2_outbox_bozuk();'
try {
    Invoke-ServiceSqlStdin $dropTrigger | Out-Null
    Invoke-ServiceSqlStdin $createTrigger | Out-Null
    Write-Host '  Trigger kuruldu: erp_outbox''a her INSERT hata verecek.'

    $before = @(Get-ServiceRows 'SELECT count(*), (SELECT count(*) FROM erp_outbox), (SELECT last_value FROM invoice_number_seq) FROM invoices;')[0] -split '\|'
    $r = New-ServiceInvoice
    $after = @(Get-ServiceRows 'SELECT count(*), (SELECT count(*) FROM erp_outbox), (SELECT last_value FROM invoice_number_seq) FROM invoices;')[0] -split '\|'
    Write-Host "  HTTP $($r.HttpStatus)"
}
finally {
    Invoke-ServiceSqlStdin $dropTrigger | Out-Null
    Write-Host '  Trigger kaldırıldı.'
}
$lost = 'FTR-{0:D6}' -f [long]$after[2]

Write-DbHeader 'Outbox yazılamayınca fatura da yazılmadı mı' "Bu denemede alınan numara: $lost"
Show-ServiceQuery "SELECT count(*) AS fatura FROM invoices WHERE invoice_number = '$lost';"
Show-ServiceQuery "SELECT count(*) AS outbox FROM erp_outbox WHERE invoice_number = '$lost';"
Write-Host '  (Numara sequence''ten transaction''dan önce alınır, bu yüzden harcanır; Gün 2''den beri böyle: numara tekrar kullanılmaz.)' -ForegroundColor DarkGray
$ok = Write-DbVerdict 'POST 500; invoices ve erp_outbox satır sayısı değişmedi' `
    "POST $($r.HttpStatus); invoices $($before[0]) -> $($after[0]), erp_outbox $($before[1]) -> $($after[1])" `
    ($r.HttpStatus -eq 500 -and $before[0] -eq $after[0] -and $before[1] -eq $after[1])
$allPassed = $allPassed -and $ok

Write-Step 'Trigger kaldırıldıktan sonra yine çalışıyor mu'
$r = New-ServiceInvoice
Write-Host ('  {0,-12} -> {1} {2}' -f $r.InvoiceNumber, $r.HttpStatus, $r.Status)
$outbox = [int]@(Get-ServiceRows "SELECT count(*) FROM erp_outbox WHERE invoice_number = '$($r.InvoiceNumber)';")[0]
$ok = Write-DbVerdict '202 Bekliyor, 1 outbox kaydı' "$($r.HttpStatus) $($r.Status), $outbox outbox kaydı" `
    ($r.HttpStatus -eq 202 -and $r.Status -eq 'Bekliyor' -and $outbox -eq 1)
$allPassed = $allPassed -and $ok

Write-Result $allPassed 'POST faturayı ve outbox kaydını birlikte yazıyor (biri yazılamazsa ikisi de yok), 202 dönüyor, simülatöre gitmiyor'
