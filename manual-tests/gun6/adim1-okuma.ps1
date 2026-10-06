# Gün 6 - Adım 1: Fatura Servisi okuma uç noktaları (liste, özet, detay) ve CORS. ~30 sn.
#
#   Her cevap aynı anda veritabanından okunan değerle karşılaştırılır: özet sayıları (durum başına ve takılı),
#   listenin toplamı / sırası / sayfa boyutu sınırı / aranan numara, bir faturanın detayındaki outbox, haber ve bulgular.
#   CORS: ekranın adresi (http://localhost:5100) ön istekte izin alır, başka bir adres almaz.
#
# Önce servisin yeni kodla derlenmiş olması gerekir: docker compose up -d --build invoice-service
# Kayıt eklemez, hiçbir şeyi değiştirmez; çalışan servisin mevcut verisine bakar.
. "$PSScriptRoot\_common.ps1"

Write-Title 'Adım 1) GET /invoices (sayfalı), /invoices/summary, /invoices/{no}/details, CORS'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service

# --- A) Özet -------------------------------------------------------------------------------------------------------
Write-DbHeader 'Fatura Servisi' 'A) /invoices/summary: durum başına sayı ve takılı fatura sayısı'
$statuses = @('Bekliyor', 'Gönderildi', 'İşleme Alındı', 'Onaylandı', 'Reddedildi', 'Başarısız')
$summary = Get-Api '/api/v1/invoices/summary'
$stuckMinutes = $summary.Json.stuckAfterMinutes
Show-ServiceQuery "SELECT status, count(*) FROM invoices GROUP BY status ORDER BY status;"
Show-ServiceQuery "SELECT count(*) AS takili FROM invoices WHERE status IN ('Gönderildi','İşleme Alındı') AND updated_at < now() - interval '$stuckMinutes minutes';"
$dbCounts = @{}
foreach ($row in @(Get-ServiceRows "SELECT status, count(*) FROM invoices GROUP BY status;")) { $p = $row -split '\|'; $dbCounts[$p[0]] = [int]$p[1] }
$dbStuck = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE status IN ('Gönderildi','İşleme Alındı') AND updated_at < now() - interval '$stuckMinutes minutes';")[0]
$expected = ($statuses | ForEach-Object { "$_=$([int]$dbCounts[$_])" }) -join ', '
$actual = ($summary.Json.counts | ForEach-Object { "$($_.status)=$($_.count)" }) -join ', '
Check (Write-DbVerdict "durum sayıları: $expected; toplam $(($dbCounts.Values | Measure-Object -Sum).Sum)" "$actual; toplam $($summary.Json.total)" `
    ($expected -eq $actual -and $summary.Json.total -eq ($dbCounts.Values | Measure-Object -Sum).Sum))
Check (Write-DbVerdict "takılı fatura: $dbStuck ($stuckMinutes dk'dan uzun Gönderildi / İşleme Alındı)" "$($summary.Json.stuckCount)" ($summary.Json.stuckCount -eq $dbStuck))

# --- B) Liste ------------------------------------------------------------------------------------------------------
Write-DbHeader 'Fatura Servisi' 'B) /invoices: toplam, sıra, sayfa boyutu sınırı, durum filtresi, arama'
$total = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices;")[0]
$page1 = Get-Api '/api/v1/invoices?page=1&pageSize=10'
Check (Write-DbVerdict "toplam $total fatura, sayfa sayısı $([math]::Ceiling($total / 10))" "$($page1.Json.totalCount) fatura, $($page1.Json.totalPages) sayfa" `
    ($page1.Json.totalCount -eq $total -and $page1.Json.totalPages -eq [math]::Ceiling($total / 10)))

Show-ServiceQuery "SELECT invoice_number, status FROM invoices ORDER BY created_at DESC, invoice_number DESC LIMIT 10;"
$dbFirst = @(Get-ServiceRows "SELECT invoice_number FROM invoices ORDER BY created_at DESC, invoice_number DESC LIMIT 10;")
Check (Write-DbVerdict "ilk sayfa, en yeni fatura üstte: $($dbFirst -join ', ')" "$(($page1.Json.items | ForEach-Object { $_.invoiceNumber }) -join ', ')" `
    (($dbFirst -join ',') -eq (($page1.Json.items | ForEach-Object { $_.invoiceNumber }) -join ',')))

$lastPage = [math]::Ceiling($total / 10)
$last = Get-Api "/api/v1/invoices?page=$lastPage&pageSize=10"
$lastExpected = $total - ($lastPage - 1) * 10
Check (Write-DbVerdict "son sayfa ($lastPage): $lastExpected kayıt" "$($last.Json.items.Count) kayıt" ($last.Json.items.Count -eq $lastExpected))

$beyond = Get-Api "/api/v1/invoices?page=$($lastPage + 1)&pageSize=10"
Check (Write-DbVerdict 'son sayfadan sonrası: 200, boş liste' "HTTP $($beyond.Status), $($beyond.Json.items.Count) kayıt" ($beyond.Status -eq 200 -and $beyond.Json.items.Count -eq 0))

$max = Get-Api '/api/v1/invoices?pageSize=100'
$tooBig = Get-Api '/api/v1/invoices?pageSize=101'
$zero = Get-Api '/api/v1/invoices?page=0'
$badStatus = Get-Api '/api/v1/invoices?status=Yok'
Check (Write-DbVerdict 'pageSize=100: 200; 101: 400; page=0: 400; geçersiz durum: 400' `
    "$($max.Status); $($tooBig.Status); $($zero.Status); $($badStatus.Status)" `
    ($max.Status -eq 200 -and $tooBig.Status -eq 400 -and $zero.Status -eq 400 -and $badStatus.Status -eq 400))

foreach ($status in $statuses) {
    $r = Get-Api "/api/v1/invoices?pageSize=1&status=$([Uri]::EscapeDataString($status))"
    Check (Write-DbVerdict "durum '$status': $([int]$dbCounts[$status]) fatura" "$($r.Json.totalCount)" ($r.Json.totalCount -eq [int]$dbCounts[$status]))
}

$term = ($dbFirst[0] -replace '^FTR-0*', '')
$term = $term.Substring(0, [math]::Max(1, $term.Length - 1))
Show-ServiceQuery "SELECT count(*) FROM invoices WHERE invoice_number ILIKE '%$term%';"
$dbSearch = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE invoice_number ILIKE '%$term%';")[0]
$search = Get-Api "/api/v1/invoices?search=$term&pageSize=1"
Check (Write-DbVerdict "arama '$term': $dbSearch fatura" "$($search.Json.totalCount)" ($search.Json.totalCount -eq $dbSearch))
$percent = Get-Api '/api/v1/invoices?search=%25&pageSize=1'
Check (Write-DbVerdict "arama '%' (joker değil, düz karakter): 0 fatura" "$($percent.Json.totalCount)" ($percent.Json.totalCount -eq 0))

# --- C) Detay ------------------------------------------------------------------------------------------------------
Write-DbHeader 'Fatura Servisi' 'C) /invoices/{no}/details: outbox, haberler, bulgular'
# Yalnızca serviste olan faturalar: serviste olmayan bir faturanın (örn. "Serviste Yok" bulgusu) detayı yoktur, 404 doğrudur.
$withEvents = @(Get-ServiceRows "SELECT e.invoice_number FROM erp_webhook_events e JOIN invoices i USING (invoice_number) GROUP BY e.invoice_number HAVING count(*) >= 2 ORDER BY max(e.received_at) DESC LIMIT 1;")
$withFindings = @(Get-ServiceRows "SELECT f.invoice_number FROM reconciliation_findings f JOIN invoices i USING (invoice_number) ORDER BY f.id DESC LIMIT 1;")
$candidates = @($withEvents + $withFindings | Where-Object { $_ } | Select-Object -Unique)
if ($candidates.Count -eq 0) { $candidates = @($dbFirst[0]) }
foreach ($number in $candidates) {
    Write-Host ''
    Write-Host "  $number" -ForegroundColor Yellow
    $detail = Get-Api "/api/v1/invoices/$number/details"
    Show-ServiceQuery "SELECT status, attempt_count, next_attempt_at, last_error FROM erp_outbox WHERE invoice_number = '$number';"
    Show-ServiceQuery "SELECT event_id, event_type, status, ignore_reason, delivery_count FROM erp_webhook_events WHERE invoice_number = '$number' ORDER BY received_at, occurred_at;"
    Show-ServiceQuery "SELECT id, run_id, finding_type, action FROM reconciliation_findings WHERE invoice_number = '$number' ORDER BY id DESC;"
    $dbOutbox = @(Get-ServiceRows "SELECT status, attempt_count FROM erp_outbox WHERE invoice_number = '$number';")
    $dbEvents = @(Get-ServiceRows "SELECT event_id, status, coalesce(ignore_reason, ''), delivery_count FROM erp_webhook_events WHERE invoice_number = '$number' ORDER BY received_at, occurred_at;")
    $dbFindings = @(Get-ServiceRows "SELECT id FROM reconciliation_findings WHERE invoice_number = '$number' ORDER BY id DESC;")
    $apiOutbox = if ($detail.Json.outbox) { "$($detail.Json.outbox.status)|$($detail.Json.outbox.attemptCount)" } else { '' }
    $apiEvents = @($detail.Json.events | ForEach-Object { "$($_.eventId)|$($_.status)|$(if ($_.ignoreReason) { $_.ignoreReason } else { '' })|$($_.deliveryCount)" })
    $apiFindings = @($detail.Json.findings | ForEach-Object { "$($_.id)" })
    Check (Write-DbVerdict "outbox: $($dbOutbox -join '')" $apiOutbox ($apiOutbox -eq ($dbOutbox -join '')))
    Check (Write-DbVerdict "$($dbEvents.Count) haber, aynı sırada, aynı durum / neden / kaç kez geldiği" "$($apiEvents.Count) haber" (($apiEvents -join ';') -eq ($dbEvents -join ';')))
    Check (Write-DbVerdict "$($dbFindings.Count) bulgu, en yeni üstte" "$($apiFindings.Count) bulgu" (($apiFindings -join ',') -eq ($dbFindings -join ',')))
}
$missing = Get-Api '/api/v1/invoices/FTR-999999/details'
Check (Write-DbVerdict 'olmayan fatura: 404' "HTTP $($missing.Status)" ($missing.Status -eq 404))

# --- D) CORS -------------------------------------------------------------------------------------------------------
Write-DbHeader 'Fatura Servisi' 'D) CORS ön isteği (OPTIONS): hangi adrese izin veriliyor'
$allowed = Get-PreflightAllowOrigin '/api/v1/invoices/resend' 'http://localhost:5100'
$foreign = Get-PreflightAllowOrigin '/api/v1/invoices/resend' 'http://baska-site.example'
Check (Write-DbVerdict 'ekranın adresi (http://localhost:5100): izin var' "Access-Control-Allow-Origin: '$allowed'" ($allowed -eq 'http://localhost:5100'))
Check (Write-DbVerdict 'başka bir adres: izin yok' "Access-Control-Allow-Origin: '$foreign'" ($foreign -eq ''))

Write-Result $allPassed 'okuma uç noktaları veritabanıyla aynı, CORS yalnızca ekranın adresine açık'
