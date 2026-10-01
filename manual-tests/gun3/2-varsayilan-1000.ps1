# Gün 3 - Madde 2: varsayılan oranlarla 1000 fatura gönder, kuyruk boşalana kadar bekle, sonucu tabloyla ver.
# Tablonun altına kuyruğun kaç saniyede boşaldığı (ilk POST'tan son faturanın Bekliyor'dan çıkmasına kadar) ve
# fatura başına ortalama deneme sayısı yazılır. ~3 dk.
# Tablo iki kez hesaplanır: simülatörün GET endpoint'iyle (karşılaştırma script'i) ve doğrudan iki veritabanından;
# ikisi aynı olmalı.
. "$PSScriptRoot\_common.ps1"

Write-Title '2) Varsayılan oranlar -> 1000 fatura, kuyruk boşalana kadar bekle, sonuç tablosu'

Wait-Service
Restart-Simulator

Write-Step '1000 fatura oluşturuluyor'
$watch = [Diagnostics.Stopwatch]::StartNew()
$range = New-ServiceInvoices 1000
Write-Host ("  Oluşturma {0:N1} sn sürdü." -f $watch.Elapsed.TotalSeconds)

Write-Step 'Kuyruk boşalana kadar bekleniyor (GET /api/v1/invoices?status=Bekliyor)'
Wait-QueueDrained $range.From $range.To 900 | Out-Null
$drained = [math]::Round($watch.Elapsed.TotalSeconds, 1)
Write-Host "  Kuyruk ilk POST'tan $drained sn sonra boşaldı."

$where = "invoice_number BETWEEN '$($range.From)' AND '$($range.To)'"
$avgAttempts = @(Get-ServiceRows "SELECT round(avg(attempt_count), 2) FROM erp_outbox WHERE $where;")[0]

Write-Step 'Karşılaştırma: servisteki her fatura simülatörün GET endpoint''iyle sorgulanıyor (1000 istek)'
$http = Compare-Invoices -From $range.From -To $range.To -Quiet
$db = Get-DbComparison $range.From $range.To
$sentFailed = @(Get-ServiceRows "SELECT count(*) FILTER (WHERE status = 'Gönderildi'), count(*) FILTER (WHERE status = 'Başarısız'), count(*) FILTER (WHERE status = 'Bekliyor') FROM invoices WHERE $where;")[0] -split '\|'
$refDiff = $db.SentFound - $db.ReferenceMatches

Write-Host ''
Write-Host ('  {0,-46} {1,14}' -f 'Durum', 'Fatura sayısı') -ForegroundColor Cyan
Write-Host ('  ' + ('-' * 62)) -ForegroundColor Cyan
Write-Host ('  {0,-46} {1,14}' -f 'Serviste Gönderildi', $sentFailed[0])
Write-Host ('  {0,-46} {1,14}' -f 'Serviste Başarısız', $sentFailed[1])
Write-Host ('  {0,-46} {1,14}' -f 'Simülatörde birden fazla kaydı olan', $db.MultipleRecords)
Write-Host ('  {0,-46} {1,14}' -f 'Serviste Gönderildi ama simülatörde olmayan', $db.SentMissing)
Write-Host ('  {0,-46} {1,14}' -f 'erp_reference değeri iki tarafta farklı olan', $refDiff)
Write-Host ('  ' + ('-' * 62)) -ForegroundColor Cyan
Write-Host "  Kuyruk $drained saniyede boşaldı; fatura başına ortalama deneme: $avgAttempts"

Write-DbHeader 'Madde 2: varsayılan oranlar, 1000 fatura' "Fatura aralığı: $($range.From) .. $($range.To)"
Show-ServiceQuery "SELECT status, count(*) AS fatura FROM invoices WHERE $where GROUP BY 1 ORDER BY 1;"
Show-ServiceQuery ("SELECT attempt_count AS deneme, count(*) AS fatura FROM erp_outbox WHERE $where GROUP BY 1 ORDER BY 1;")
Show-ErpQuery "SELECT behavior, count(*) AS kayit FROM invoices WHERE $where GROUP BY 1 ORDER BY 1;"
Show-ErpQuery "SELECT count(*) AS kayit, count(DISTINCT invoice_number) AS farkli_fatura FROM invoices WHERE $where;"
$ok = Write-DbVerdict ('Bekliyor kalan 0; Gönderildi + Başarısız = 1000; birden fazla kaydı olan 0; Gönderildi ama simülatörde olmayan 0; ' +
    'erp_reference farklı olan 0; GET endpoint''iyle bulunan tablo veritabanındakiyle aynı') `
    ("Bekliyor $($sentFailed[2]); $($sentFailed[0]) + $($sentFailed[1]); birden fazla $($db.MultipleRecords); Gönderildi+yok $($db.SentMissing); " +
     "referans farklı $refDiff; tablolar $(if ((Format-Comparison $db) -eq (Format-Comparison $http)) { 'aynı' } else { 'FARKLI' })") `
    ($sentFailed[2] -eq '0' -and ([int]$sentFailed[0] + [int]$sentFailed[1]) -eq 1000 -and $db.MultipleRecords -eq 0 -and
     $db.SentMissing -eq 0 -and $refDiff -eq 0 -and (Format-Comparison $db) -eq (Format-Comparison $http))

Write-Result $ok "1000 fatura: $($sentFailed[0]) Gönderildi, $($sentFailed[1]) Başarısız; çift kayıt $($db.MultipleRecords), kayıp $($db.SentMissing), farklı referans $refDiff; kuyruk $drained sn, ortalama $avgAttempts deneme"
