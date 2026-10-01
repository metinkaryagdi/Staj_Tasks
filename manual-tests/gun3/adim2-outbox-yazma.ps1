# Gün 3 - Adım 2: POST faturayı ve erp_outbox kaydını aynı transaction'da yazıyor, 202 dönüyor, simülatörü beklemiyor.
# (Kontrol listesinin parçası değil, adımın kendi testi. Worker'ın olduğu son sürümde de geçer.)
#
#   1) Simülatör LateResponse %100 (her isteği 30 sn bekletir) iken 5 fatura: POST simülatöre gitseydi her cevap en az
#      10 sn (zaman aşımı) sürerdi. Hepsi milisaniyeler içinde 202 + Bekliyor + 0 deneme dönüyor; her faturanın tam bir
#      erp_outbox kaydı var ve ikisi aynı anda (aynı created_at, aynı transaction) yazılmış; servis logunda gönderim
#      ("ERP send start") her zaman "Invoice queued" satırından sonra, arka plandaki worker'dan geliyor.
#   2) Aynı transaction: erp_outbox'a yazmayı geçici bir trigger ile bozuyoruz. POST hata almalı ve fatura da
#      yazılmamalı (yarım kayıt yok). Trigger script sonunda her durumda kaldırılır.
. "$PSScriptRoot\_common.ps1"

Write-Title 'Adım 2) POST: fatura + erp_outbox aynı transaction''da, 202, simülatörü beklemiyor'

Write-Step 'Fatura Servisi yeni kodla derlenip yeniden başlatılıyor...'
Invoke-Compose @('up', '-d', '--build', 'invoice-service')
Wait-Service
Restart-Simulator @{ Simulator__Rates__Success = 0; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0
                     Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 100 }

$allPassed = $true

# --- 1) 5 fatura ------------------------------------------------------------------------------------------------
Write-Step '5 fatura oluşturuluyor (simülatör her isteği 30 sn bekletiyor)'
$results = @()
for ($i = 0; $i -lt 5; $i++) {
    $r = New-ServiceInvoice
    $results += $r
    Write-Host ('  {0,-12} -> {1} {2,-9} deneme={3}  süre={4}s' -f $r.InvoiceNumber, $r.HttpStatus, $r.Status, $r.Attempts, $r.Seconds)
}
$from = $results[0].InvoiceNumber
$to = $results[-1].InvoiceNumber
$httpOk = @($results | Where-Object { $_.HttpStatus -eq 202 -and $_.Status -eq 'Bekliyor' -and $_.Attempts -eq 0 -and $_.Seconds -lt 1 }).Count
Write-Host ''
$ok = Write-DbVerdict '5 cevabın hepsi 1 sn''den kısa sürede 202, status Bekliyor, deneme 0 (simülatör beklenmedi)' "$httpOk/5" ($httpOk -eq 5)
$allPassed = $allPassed -and $ok

$range = "invoice_number BETWEEN '$from' AND '$to'"
Write-DbHeader 'Fatura ve outbox kayıtları' "Fatura aralığı: $from .. $to"
Write-Host '  (Worker faturaları hemen almaya başlar; deneme sayısı ve durum bu yüzden değişmiş olabilir. Kontrol edilen:' -ForegroundColor DarkGray
Write-Host '   her faturanın tam bir outbox kaydı var ve ikisi aynı transaction''da, aynı created_at ile yazılmış.)' -ForegroundColor DarkGray
Show-ServiceQuery "SELECT invoice_number, status, send_attempt_count, created_at FROM invoices WHERE $range ORDER BY 1;"
Show-ServiceQuery "SELECT id, invoice_number, status, attempt_count, created_at, locked_by FROM erp_outbox WHERE $range ORDER BY id;"

$pairs = [int]@(Get-ServiceRows ("SELECT count(*) FROM invoices i JOIN erp_outbox o USING (invoice_number) " +
    "WHERE i.$range AND i.created_at = o.created_at;"))[0]
$outboxRows = [int]@(Get-ServiceRows "SELECT count(*) FROM erp_outbox WHERE $range;")[0]

# Servis logu: her fatura için "Invoice queued" (POST isteği) satırı, "ERP send start" (worker) satırından önce.
Start-Sleep -Seconds 1
$inv = [Globalization.CultureInfo]::InvariantCulture
$queued = @{}; $started = @{}
foreach ($line in Get-ServiceLog) {
    if ($line -match '^(\S+ \S+) info: .*Invoice queued invoice=(\S+)') { $queued[$Matches[2]] = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss.fff', $inv) }
    elseif ($line -match '^(\S+ \S+) info: .*ERP send start invoice=(\S+) attempt=1/') { $started[$Matches[2]] = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss.fff', $inv) }
}
Write-Host ''
Write-Host '  Servis logu (fatura -> kuyruğa alındı, worker gönderime başladı):' -ForegroundColor DarkGray
$ordered = 0
foreach ($r in $results) {
    $q = $queued[$r.InvoiceNumber]; $s = $started[$r.InvoiceNumber]
    Write-Host ('    {0}  queued {1}  send start {2}' -f $r.InvoiceNumber, $(if ($q) { $q.ToString('HH:mm:ss.fff') } else { '-' }), $(if ($s) { $s.ToString('HH:mm:ss.fff') } else { '-' }))
    if ($q -and $s -and $q -le $s) { $ordered++ }
}
Write-Host ''
$ok = Write-DbVerdict ('5 fatura, her birinin tam bir outbox kaydı var, aynı created_at; logda 5 faturanın hepsi önce kuyruğa alınmış, ' +
    'sonra worker göndermeye başlamış') `
    "$pairs fatura+outbox çifti (aynı created_at), $outboxRows outbox kaydı; logda sırası doğru olan $ordered fatura" `
    ($pairs -eq 5 -and $outboxRows -eq 5 -and $ordered -eq 5)
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

Restart-Simulator

Write-Result $allPassed 'POST faturayı ve outbox kaydını birlikte yazıyor (biri yazılamazsa ikisi de yok), 202 dönüyor, simülatörü beklemiyor'
