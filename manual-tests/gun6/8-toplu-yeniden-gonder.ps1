# Gün 6 - Madde 8: 20 Başarısız faturayı toplu olarak yeniden gönder; sonuç özeti doğru mu. ~3 dk.
#
#   Ekranın "Seçilenleri Yeniden Gönder" düğmesi POST /invoices/resend çağırır; bu script aynı çağrıyı yapar ve özeti veritabanıyla
#   karşılaştırır. İstekte 20 Başarısız fatura, 1 Başarısız olmayan (Onaylandı) ve 1 olmayan numara var:
#   özet "20 kuyruğa alındı, 2 alınamadı (biri Başarısız değil, biri bulunamadı)" olmalı; veritabanında 20 faturanın hepsi artık
#   Başarısız değil (Bekliyor ya da worker aldıysa sonrası), Onaylandı olan Onaylandı kalmalı, her birinin erp_outbox kaydı
#   sıfırlanmış olmalı. Sonra kuyruk boşalana kadar beklenir ve faturaların yeni durumları gösterilir.
#
#   Veritabanında zaten Başarısız olan en yeni 20 faturayı kullanır (yoksa hata verir); ayrıca Başarısız fatura üretmek isterseniz
#   önce başka bir test (örn. gun3\3-erp-kapali.ps1 ya da gun5\9-simulator-durdu.ps1) çalıştırılabilir.
. "$PSScriptRoot\_common.ps1"

Write-Title 'Madde 8) 20 Başarısız fatura toplu yeniden gönderiliyor: sonuç özeti'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
$failed = @(Get-ServiceRows "SELECT invoice_number FROM invoices WHERE status = 'Başarısız' ORDER BY created_at DESC, invoice_number DESC LIMIT 20;")
if ($failed.Count -lt 20) { throw "Veritabanında en az 20 Başarısız fatura gerekiyor ($($failed.Count) var)." }
$approved = @(Get-ServiceRows "SELECT invoice_number FROM invoices WHERE status = 'Onaylandı' ORDER BY created_at DESC LIMIT 1;")[0]
$missing = 'FTR-999999'
$list = InList $failed

Write-DbHeader 'Fatura Servisi' 'İstekten önce: 20 fatura'
Show-ServiceQuery "SELECT status, count(*) AS fatura, min(send_attempt_count) AS en_az_deneme, max(send_attempt_count) AS en_cok_deneme FROM invoices WHERE invoice_number IN ($list) GROUP BY status;"
$before = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE status = 'Başarısız';")[0]

$response = Post-Api '/api/v1/invoices/resend' (ConvertTo-ResendBody @($failed + $approved + $missing))
$queued = @($response.Json.results | Where-Object { $_.result -eq 'queued' })
$refused = @($response.Json.results | Where-Object { $_.result -ne 'queued' })
Write-Host ''
Write-Host "  Sonuç özeti: $($queued.Count) fatura kuyruğa alındı, $($refused.Count) fatura alınamadı." -ForegroundColor Cyan
foreach ($r in $refused) { Write-Host "    $($r.invoiceNumber): $($r.result)$(if ($r.currentStatus) { " (şu an $($r.currentStatus))" })" -ForegroundColor Cyan }

Check (Write-DbVerdict '200; 20 kuyruğa alındı; 2 alınamadı: Onaylandı olan not_failed (Onaylandı), olmayan not_found' `
    "HTTP $($response.Status); $($queued.Count) kuyruğa alındı; $(($refused | ForEach-Object { "$($_.invoiceNumber)=$($_.result)" }) -join ', ')" `
    ($response.Status -eq 200 -and $queued.Count -eq 20 -and $refused.Count -eq 2 -and
     @($refused | Where-Object { $_.invoiceNumber -eq $approved -and $_.result -eq 'not_failed' -and $_.currentStatus -eq 'Onaylandı' }).Count -eq 1 -and
     @($refused | Where-Object { $_.invoiceNumber -eq $missing -and $_.result -eq 'not_found' }).Count -eq 1 ))

Write-DbHeader 'Fatura Servisi' 'İstekten hemen sonra'
Show-ServiceQuery "SELECT status, count(*) AS fatura FROM invoices WHERE invoice_number IN ($list) GROUP BY status ORDER BY status;"
Show-ServiceQuery "SELECT status, count(*) AS kayit, max(attempt_count) AS en_cok_deneme FROM erp_outbox WHERE invoice_number IN ($list) GROUP BY status ORDER BY status;"
$stillFailed = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status = 'Başarısız';")[0]
$after = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE status = 'Başarısız';")[0]
$approvedNow = @(Get-ServiceRows "SELECT status FROM invoices WHERE invoice_number = '$approved';")[0]
Check (Write-DbVerdict "20 fatura artık Başarısız değil; toplam Başarısız $before -> $($before - 20) (yeni başarısızlık olmadıysa); $approved Onaylandı kaldı" `
    "$stillFailed tanesi hâlâ Başarısız; toplam Başarısız $after; $approved = $approvedNow" ($stillFailed -eq 0 -and $approvedNow -eq 'Onaylandı'))

Write-Step 'Kuyruk boşalana kadar bekleniyor'
$watch = [Diagnostics.Stopwatch]::StartNew()
while ($true) {
    $pending = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status = 'Bekliyor';")[0]
    if ($pending -eq 0) { break }
    if ($watch.Elapsed.TotalSeconds -gt 900) { throw "20 faturanın kuyruğu 15 dk içinde boşalmadı ($pending Bekliyor)." }
    Start-Sleep -Seconds 2
}
Write-DbHeader 'Fatura Servisi' "Kuyruk $([math]::Round($watch.Elapsed.TotalSeconds)) sn sonra boşaldı: faturaların yeni durumları"
Show-ServiceQuery "SELECT status, count(*) AS fatura FROM invoices WHERE invoice_number IN ($list) GROUP BY status ORDER BY status;"
$stillPending = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status = 'Bekliyor';")[0]
Check (Write-DbVerdict 'kuyruk boşaldı: 0 fatura Bekliyor' "$stillPending" ($stillPending -eq 0))

Write-Result $allPassed 'toplu yeniden göndermenin sonuç özeti veritabanıyla uyumlu'
