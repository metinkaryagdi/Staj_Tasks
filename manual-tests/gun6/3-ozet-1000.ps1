# Gün 6 - Madde 3: varsayılan oranlarla 1000 fatura gönder; Özet sayfasının gösterdiği sayılar veritabanıyla birebir aynı mı. ~5 dk.
#
#   Simülatör varsayılan ayarlarla yeniden başlatılır, 1000 fatura gönderilir, kuyruk boşalana ve haberler bitene kadar beklenir.
#   Sonra Özet sayfasının okuduğu uç nokta (GET /invoices/summary) ile veritabanı aynı anda karşılaştırılır: durum başına sayı,
#   toplam ve takılı fatura sayısı. Ekranın kendisi ayrıca tarayıcıda açılıp bu sayılarla karşılaştırılır (ekran görüntüsü).
#
# Önce servisin ve ekranın yeni kodla derlenmiş olması gerekir: docker compose up -d --build
. "$PSScriptRoot\_common.ps1"

Write-Title 'Madde 3) Varsayılan oranlar, 1000 fatura: Özet sayıları = veritabanı'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
Restart-Simulator

Write-Step '1000 fatura oluşturuluyor'
$watch = [Diagnostics.Stopwatch]::StartNew()
$range = New-ServiceInvoices 1000
Write-Host ("  Oluşturma {0:N1} sn sürdü." -f $watch.Elapsed.TotalSeconds)

Write-Step 'Kuyruk boşalana kadar bekleniyor'
Wait-QueueDrained $range.From $range.To 900 | Out-Null
Write-Host ("  Kuyruk ilk POST'tan {0:N1} sn sonra boşaldı." -f $watch.Elapsed.TotalSeconds)

Write-Step 'Simülatörün haberleri bitene kadar bekleniyor'
$eventWatch = [Diagnostics.Stopwatch]::StartNew()
while ($true) {
    $waiting = [int]@(Get-ErpRows "SELECT count(*) FROM webhook_deliveries WHERE invoice_number BETWEEN '$($range.From)' AND '$($range.To)' AND status IN ('Pending', 'Waiting');")[0]
    if ($waiting -eq 0) { break }
    if ($eventWatch.Elapsed.TotalSeconds -gt 600) { throw "Haberler 10 dk içinde bitmedi ($waiting bekliyor)." }
    Start-Sleep -Seconds 2
}
Write-Host ("  Haberler {0:N0} sn sonra bitti." -f $eventWatch.Elapsed.TotalSeconds)

Write-DbHeader 'Fatura Servisi' "Özet sayfasının sayıları (fatura aralığı $($range.From) .. $($range.To) dahil, bütün veritabanı)"
$s = Get-StableSummary
Show-ServiceQuery "SELECT status, count(*) AS fatura FROM invoices GROUP BY status ORDER BY status;"
Show-ServiceQuery "SELECT count(*) AS toplam FROM invoices;"
Show-ServiceQuery "SELECT count(*) AS takili FROM invoices WHERE status IN ('Gönderildi','İşleme Alındı') AND updated_at < now() - interval '$($s.Api.stuckAfterMinutes) minutes';"

$dbTotal = ($s.Db.Values | Measure-Object -Sum).Sum
foreach ($status in $s.Statuses) {
    $apiCount = ($s.Api.counts | Where-Object { $_.status -eq $status }).count
    Check (Write-DbVerdict "$status = $([int]$s.Db[$status])" "$apiCount" ($apiCount -eq [int]$s.Db[$status]))
}
Check (Write-DbVerdict "toplam = $dbTotal" "$($s.Api.total)" ($s.Api.total -eq $dbTotal))
Check (Write-DbVerdict "takılı = $($s.DbStuck)" "$($s.Api.stuckCount)" ($s.Api.stuckCount -eq $s.DbStuck))

$where = "invoice_number BETWEEN '$($range.From)' AND '$($range.To)'"
Show-ServiceQuery "SELECT status, count(*) AS fatura FROM invoices WHERE $where GROUP BY 1 ORDER BY 1;"
$inRange = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE $where;")[0]
Check (Write-DbVerdict '1000 fatura serviste (Özet toplamı bunu da içeriyor)' "$inRange" ($inRange -eq 1000))

Write-Host ''
Write-Host '  Ekranı karşılaştırmak için: http://localhost:5100 (Özet) açın; yukarıdaki sayılarla aynı olmalı.' -ForegroundColor DarkGray
Write-Result $allPassed 'Özet sayıları veritabanıyla birebir aynı'
