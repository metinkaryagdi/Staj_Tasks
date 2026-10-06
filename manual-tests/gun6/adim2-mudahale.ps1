# Gün 6 - Adım 2: toplu resend (POST /invoices/resend) ve reddedilen müdahalelerin makine kodları. ~1 dk.
#
#   A) Karışık liste: Başarısız olanlar kuyruğa alınıyor, olmayan / Başarısız olmayan numaralar nedenleriyle reddediliyor,
#      aynı numara iki kez gönderilince bir kez işleniyor; veritabanında yalnızca Başarısız olanlar değişiyor.
#   B) 101 numara, boş liste, boş numara: 400, veritabanında hiçbir şey değişmiyor.
#   C) Aynı 20 Başarısız fatura için iki toplu istek aynı anda: her fatura tam bir istekte kuyruğa alınıyor, diğerinde
#      not_failed (Bekliyor) görüyor.
#   D) Tekli resend: başka biri kuyruğa aldıktan sonra 409 + code invoice_not_failed + currentStatus;
#      mutabakat çalışırken ikinci başlatma 409 + code reconciliation_running.
#
# Önce servisin yeni kodla derlenmiş olması gerekir: docker compose up -d --build invoice-service
# Kuyruğa aldığı faturalar veritabanında zaten Başarısız olanlardır (en yeni 25 tanesi); worker onları yeniden gönderir.
. "$PSScriptRoot\_common.ps1"

Write-Title 'Adım 2) Toplu resend ve reddedilen müdahaleler'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
$failed = @(Get-ServiceRows "SELECT invoice_number FROM invoices WHERE status = 'Başarısız' ORDER BY created_at DESC, invoice_number DESC LIMIT 25;")
if ($failed.Count -lt 25) { throw "Veritabanında en az 25 Başarısız fatura gerekiyor ($($failed.Count) var). Önce bir test çalıştırıp Başarısız fatura üretin." }
$approved = @(Get-ServiceRows "SELECT invoice_number FROM invoices WHERE status = 'Onaylandı' ORDER BY created_at DESC LIMIT 1;")[0]
$missing = 'FTR-999999'

# --- A) Karışık liste ----------------------------------------------------------------------------------------------
Write-DbHeader 'Fatura Servisi' 'A) Karışık liste: 3 Başarısız, 1 Onaylandı, 1 olmayan, 1 tekrar'
$three = $failed[0..2]
$list = InList @($three + $approved)
Show-ServiceQuery "SELECT invoice_number, status FROM invoices WHERE invoice_number IN ($list) ORDER BY 1;"
$a = Post-Api '/api/v1/invoices/resend' (ConvertTo-ResendBody @($three[0], $three[1], $three[2], $approved, $missing, $three[0]))
$byNumber = @{}; foreach ($item in $a.Json.results) { $byNumber[$item.invoiceNumber] = $item }
Check (Write-DbVerdict '200; 5 sonuç (tekrar bir kez): 3 queued, 1 not_failed (Onaylandı), 1 not_found' `
    "HTTP $($a.Status); $(@($a.Json.results).Count) sonuç: $((@($a.Json.results) | ForEach-Object { $_.result }) -join ', ')" `
    ($a.Status -eq 200 -and @($a.Json.results).Count -eq 5 -and
     @($three | Where-Object { $byNumber[$_].result -eq 'queued' }).Count -eq 3 -and
     $byNumber[$approved].result -eq 'not_failed' -and $byNumber[$approved].currentStatus -eq 'Onaylandı' -and
     $byNumber[$missing].result -eq 'not_found'))
Show-ServiceQuery "SELECT i.invoice_number, i.status, i.last_error, o.status AS outbox FROM invoices i LEFT JOIN erp_outbox o USING (invoice_number) WHERE i.invoice_number IN ($list) ORDER BY 1;"
$stillFailed = @(Get-ServiceRows "SELECT invoice_number FROM invoices WHERE invoice_number IN ($(InList $three)) AND status = 'Başarısız';")
$approvedNow = @(Get-ServiceRows "SELECT status FROM invoices WHERE invoice_number = '$approved';")[0]
Check (Write-DbVerdict '3 fatura artık Başarısız değil (Bekliyor ya da worker aldıysa sonrası); Onaylandı olan Onaylandı kaldı' `
    "$($stillFailed.Count) tanesi hâlâ Başarısız; $approved = $approvedNow" ($stillFailed.Count -eq 0 -and $approvedNow -eq 'Onaylandı'))

# --- B) Geçersiz istekler ------------------------------------------------------------------------------------------
Write-DbHeader 'Fatura Servisi' 'B) 101 numara, boş liste, boş numara'
$rest = @($failed[3..24])
$over = @($rest + (1..79 | ForEach-Object { "FTR-9$($_.ToString('D5'))" }))
$tooMany = Post-Api '/api/v1/invoices/resend' (ConvertTo-ResendBody $over)
$empty = Post-Api '/api/v1/invoices/resend' '{"invoiceNumbers":[]}'
$blank = Post-Api '/api/v1/invoices/resend' (ConvertTo-ResendBody @($rest[0], ' '))
$noBody = Post-Api '/api/v1/invoices/resend' '{}'
Check (Write-DbVerdict "$($over.Count) numara: 400; boş liste: 400; boş numara: 400; gövdesiz: 400" `
    "$($tooMany.Status); $($empty.Status); $($blank.Status); $($noBody.Status)" `
    ($over.Count -eq 101 -and $tooMany.Status -eq 400 -and $empty.Status -eq 400 -and $blank.Status -eq 400 -and $noBody.Status -eq 400))
$changed = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE invoice_number IN ($(InList $rest)) AND status <> 'Başarısız';")[0]
Check (Write-DbVerdict 'reddedilen isteklerden sonra 22 fatura hâlâ Başarısız' "$($rest.Count - $changed) tanesi Başarısız" ($changed -eq 0))

# --- C) Aynı anda iki toplu istek ----------------------------------------------------------------------------------
Write-DbHeader 'Fatura Servisi' 'C) Aynı 20 Başarısız fatura için iki toplu istek aynı anda'
$twenty = @($rest[0..19])
$body = ConvertTo-ResendBody $twenty
$t1 = Start-ApiPost '/api/v1/invoices/resend' $body
$t2 = Start-ApiPost '/api/v1/invoices/resend' $body
$r1 = Receive-Api $t1; $r2 = Receive-Api $t2
$queued1 = @($r1.Json.results | Where-Object { $_.result -eq 'queued' }).Count
$queued2 = @($r2.Json.results | Where-Object { $_.result -eq 'queued' }).Count
$refused = @(@($r1.Json.results) + @($r2.Json.results) | Where-Object { $_.result -eq 'not_failed' }).Count
Check (Write-DbVerdict '20 fatura iki istekte toplam 20 kez queued, 20 kez not_failed (hiçbiri iki kez kuyruğa alınmadı)' `
    "istek 1: $queued1 queued; istek 2: $queued2 queued; toplam not_failed: $refused" `
    ($r1.Status -eq 200 -and $r2.Status -eq 200 -and ($queued1 + $queued2) -eq 20 -and $refused -eq 20))
$both = @($twenty | ForEach-Object { $n = $_; $x = @($r1.Json.results + $r2.Json.results | Where-Object { $_.invoiceNumber -eq $n -and $_.result -eq 'queued' }).Count; $x }) | Where-Object { $_ -ne 1 }
Check (Write-DbVerdict 'her faturanın tam bir istekte queued olduğu' "$(@($both).Count) fatura için sayı 1 değil" (@($both).Count -eq 0))
Show-ServiceQuery "SELECT status, count(*) FROM invoices WHERE invoice_number IN ($(InList $twenty)) GROUP BY status ORDER BY status;"

# --- D) Tekli resend ve mutabakat 409'ları -------------------------------------------------------------------------
Write-DbHeader 'Fatura Servisi' 'D) 409 cevaplarının code alanı'
$one = $failed[24]
$first = Post-Api "/api/v1/invoices/$one/resend"
$second = Post-Api "/api/v1/invoices/$one/resend"
Check (Write-DbVerdict 'ilk tekli resend 202 (ya da önceki adımda kuyruğa alındıysa 409), ikinci 409 + code invoice_not_failed + currentStatus' `
    "ilk: $($first.Status); ikinci: $($second.Status) code=$($second.Code) currentStatus=$($second.Json.currentStatus)" `
    ($second.Status -eq 409 -and $second.Code -eq 'invoice_not_failed' -and $second.Json.currentStatus))
$unknown = Post-Api "/api/v1/invoices/$missing/resend"
Check (Write-DbVerdict 'olmayan fatura: 404 + code invoice_not_found' "$($unknown.Status) code=$($unknown.Code)" ($unknown.Status -eq 404 -and $unknown.Code -eq 'invoice_not_found'))

$run1 = Post-Api '/api/v1/reconciliation-runs'
$run2 = Post-Api '/api/v1/reconciliation-runs'
Check (Write-DbVerdict 'mutabakat çalışırken ikinci başlatma: 409 + code reconciliation_running' `
    "ilk: $($run1.Status); ikinci: $($run2.Status) code=$($run2.Code)" ($run1.Status -eq 202 -and $run2.Status -eq 409 -and $run2.Code -eq 'reconciliation_running'))
if ($run1.Status -eq 202) { Wait-RunDone ([long]$run1.Json.id) 600 | Out-Null }

Write-Result $allPassed 'toplu resend fatura başına sonuç veriyor, aynı anda iki istek bir faturayı iki kez kuyruğa almıyor, 409 cevapları kod taşıyor'
