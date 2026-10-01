# Gün 3 - Madde 5: simülatörü durdur, 50 fatura gönder, 2 dakika bekle, simülatörü başlat.
# Simülatör kapalıyken POST isteklerinin 202 döndüğü, simülatör açıldıktan sonra 50 faturanın da Gönderildi olduğu ve
# simülatörde çift kayıt olmadığı gösterilir. Simülatör appsettings.json ayarlarıyla (varsayılan oranlar) başlatılır. ~4 dk.
#
# Kapalıyken: ilk deneme simülatöre ulaşamaz; sonraki denemelerde servis önce simülatöre sorar, soramadığı için
# ("unknown") POST yapmaz ve katlanarak artan bekleme ile tekrar dener.
. "$PSScriptRoot\_common.ps1"
# Script bir hatayla yarıda kesilirse simülatör değiştirilmiş ayarda (ör. ServerError %100 ya da durdurulmuş) kalıp sonraki
# testleri bozmasın: varsayılan ayarlarına döndürülür, hata yine yukarı iletilir.
trap { Write-Host "Hata: $_ - simülatör varsayılan ayarlarına döndürülüyor." -ForegroundColor Red; try { Restart-Simulator } catch { }; break }

Write-Title '5) Simülatör kapalı -> 50 fatura (202), 2 dk sonra simülatör açılıyor -> 50''si Gönderildi, çift kayıt yok'

Wait-Service
Write-Step 'Simülatör durduruluyor'
Invoke-Compose @('stop', 'erp-simulator')
try { $null = $script:Http.GetAsync("$SimulatorUrl/health").GetAwaiter().GetResult(); $down = $false } catch { $down = $true }
Write-Host "  Simülatör $(if ($down) { 'kapalı (health isteği bağlanamadı)' } else { 'HÂLÂ AÇIK' })."

Write-Step '50 fatura oluşturuluyor'
$results = @()
for ($i = 0; $i -lt 50; $i++) { $results += New-ServiceInvoice }
$from = $results[0].InvoiceNumber; $to = $results[-1].InvoiceNumber
$accepted = @($results | Where-Object { $_.HttpStatus -eq 202 -and $_.Status -eq 'Bekliyor' }).Count
$slowest = ($results | Measure-Object Seconds -Maximum).Maximum
Write-Host "  $from .. $to : $accepted/50 cevap 202 Bekliyor, en yavaşı $slowest sn"
$postOk = Write-DbVerdict 'simülatör kapalıyken 50 POST''un hepsi 202 Bekliyor' "$accepted/50" ($down -and $accepted -eq 50)

Write-Step '2 dakika bekleniyor (simülatör kapalı)'
Start-Sleep -Seconds 120
$pendingBefore = @(Get-ServiceInvoiceNumbers 'Bekliyor' | Where-Object { $_ -ge $from -and $_ -le $to }).Count
Write-Host "  Simülatör açılmadan önce: $pendingBefore/50 fatura Bekliyor."

Restart-Simulator
$watch = [Diagnostics.Stopwatch]::StartNew()
Wait-QueueDrained $from $to 600 | Out-Null
Write-Host ("  Simülatör açıldıktan {0:N1} sn sonra kuyruk boşaldı." -f $watch.Elapsed.TotalSeconds)

$numbers = @(Get-ServiceRows "SELECT invoice_number FROM invoices WHERE invoice_number BETWEEN '$from' AND '$to' ORDER BY 1;")
$attempts = @(Get-SendAttempts $numbers)
$checks = $attempts | Group-Object Check | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Host "  Denemelerin kontrol türleri: $($checks -join ', ')" -ForegroundColor DarkGray
Write-Host '  (first = ilk gönderim; unknown = simülatöre sorulamadı, POST yapılmadı; notFound = yok, POST yapıldı; found = zaten var, POST yapılmadı)' -ForegroundColor DarkGray

Write-Step 'Karşılaştırma: servisteki her fatura simülatörün GET endpoint''iyle sorgulanıyor'
$c = Compare-Invoices -From $from -To $to

$where = "invoice_number BETWEEN '$from' AND '$to'"
Write-DbHeader 'Madde 5: simülatör kapalıyken gönderilen 50 fatura' "Fatura aralığı: $from .. $to"
Show-ServiceQuery "SELECT status, count(*) AS fatura, min(send_attempt_count) AS min_deneme, max(send_attempt_count) AS max_deneme FROM invoices WHERE $where GROUP BY 1;"
Show-ErpQuery "SELECT behavior, count(*) AS kayit, count(DISTINCT invoice_number) AS farkli_fatura FROM invoices WHERE $where GROUP BY 1 ORDER BY 1;"
Show-ErpQuery "SELECT invoice_number, count(*) AS kayit FROM invoices WHERE $where GROUP BY 1 HAVING count(*) > 1;"
$db = Get-DbComparison $from $to
Write-Host ''
$dbOk = Write-DbVerdict '50 fatura Gönderildi ve simülatörde var; birden fazla kaydı olan 0; referanslar aynı' `
    "$($db.SentFound) Gönderildi ve var; Başarısız $($db.FailedMissing + $db.FailedFound); birden fazla kaydı olan $($db.MultipleRecords); referans aynı $($db.ReferenceMatches)/$($db.SentFound)" `
    ($db.SentFound -eq 50 -and $db.MultipleRecords -eq 0 -and $db.ReferenceMatches -eq 50)

Write-Result ($postOk -and $dbOk -and $c.Unknown -eq 0) ("kapalıyken $accepted/50 POST 202; açıldıktan sonra $($db.SentFound) Gönderildi, " +
    "Başarısız $($db.FailedMissing + $db.FailedFound), çift kayıt $($db.MultipleRecords)")
