# Gün 2 - Ek test 1 (QA bulgusu 1'in düzeltmesi): aynı faturanın gönderimleri üst üste bindiğinde
# satır hep tek bir gönderimin tutarlı sonucunu taşımalı ve send_attempt_count gerçek gönderim sayısına eşit olmalı.
# Çift gönderim koruması YOK (görev gereği): iki gönderim de simülatöre gider, ERP'de iki kayıt oluşur.
#
#   A) İlk POST geç cevap bekliyor (LateResponse, servis 10 sn'de vazgeçer); bu sırada aynı faturaya resend (Success).
#      Düzeltmeden önce satır "Gönderildi + ERP referansı + zaman aşımı hatası" olarak karışıyordu.
#   B) Aynı faturaya aynı anda 10 resend. Düzeltmeden önce sayaç 11 yerine 7 gibi eksik sayıyordu.
param([int]$Parallel = 10)
. "$PSScriptRoot\_common.ps1"

# ---------------------------------------------------------------- A
Write-Title 'Ek 1-A) Geç cevap bekleyen POST sürerken aynı faturaya resend'

# Seed 42 ile Success/LateResponse %50: ilk istek LateResponse, ikinci istek Success çıkar.
Restart-Simulator @{
    Simulator__Seed                 = 42
    Simulator__Rates__Success       = 50
    Simulator__Rates__Busy          = 0
    Simulator__Rates__ServerError   = 0
    Simulator__Rates__SaveThenError = 0
    Simulator__Rates__LateResponse  = 50
}
Wait-Service

$customer = 'EK1-' + (Get-Date -Format 'HHmmss')
$json = '{"customerCode":"' + $customer + '","amount":10.00,"currency":"TRY","invoiceDate":"2026-09-30"}'
$content = New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')

Write-Step "POST $ServiceUrl/api/v1/invoices arka planda başlatıldı (simülatör 1. istek: LateResponse)"
$postWatch = [Diagnostics.Stopwatch]::StartNew()
$postTask = $script:Http.PostAsync("$ServiceUrl/api/v1/invoices", $content)
Start-Sleep -Seconds 2
$a = @(Get-ServiceRows "SELECT invoice_number FROM invoices WHERE customer_code = '$customer';")[0]
Write-Host "  Fatura: $a"
Write-Host '  2. saniyede servisteki satır (POST hâlâ ERP cevabını bekliyor):'
Invoke-ServiceSql ("SELECT invoice_number, status, erp_reference, last_error, send_attempt_count " +
    "FROM invoices WHERE invoice_number = '$a';") | Out-Host

Write-Step "POST $ServiceUrl/api/v1/invoices/$a/resend  (simülatör 2. istek: Success)"
$resend = Send-ServiceResend $a
Write-ServiceResult $resend

Write-Step 'İlk POST''un bitmesi bekleniyor (servis 10. saniyede zaman aşımına düşer)'
$post = ConvertTo-ServiceResult ($postTask.GetAwaiter().GetResult()) $postWatch
Write-ServiceResult $post

Write-Step 'Servis logu (bu fatura)'
Get-ServiceLog | Where-Object { $_ -match "ERP send invoice=$a " } | ForEach-Object { Write-Host "  $_" }

Write-DbHeader 'Ek 1-A: satır tek bir gönderimin sonucunu taşıyor mu' "Fatura numarası: $a"
Show-ServiceQuery ("SELECT invoice_number, status, erp_reference, last_error, send_attempt_count, created_at, updated_at " +
    "FROM invoices WHERE invoice_number = '$a';")
Show-ErpQuery "SELECT id, invoice_number, erp_reference, behavior, received_at FROM invoices WHERE invoice_number = '$a' ORDER BY id;"

$row = @(Get-ServiceRows "SELECT status, coalesce(erp_reference, ''), coalesce(last_error, ''), send_attempt_count FROM invoices WHERE invoice_number = '$a';")[0] -split '\|'
$erpRefs = @(Get-ErpRows "SELECT erp_reference FROM invoices WHERE invoice_number = '$a' ORDER BY id;")
$consistent = ($row[0] -eq 'Gönderildi' -and $row[1] -and -not $row[2]) -or ($row[0] -eq 'Başarısız' -and -not $row[1] -and $row[2])
Write-Host ''
$dbA = Write-DbVerdict ('Gönderildi ise erp_reference dolu ve last_error boş (Başarısız ise tersi); deneme 2; ' +
        'ERP''de 2 kayıt (çift gönderim engellenmiyor); servisteki referans ERP kayıtlarından biri') `
    ("$($row[0]), erp_reference=$(if ($row[1]) { $row[1] } else { 'boş' }), last_error=$(if ($row[2]) { 'dolu' } else { 'boş' }), " +
     "deneme $($row[3]); ERP'de $($erpRefs.Count) kayıt ($($erpRefs -join ', '))") `
    ($consistent -and [int]$row[3] -eq 2 -and $erpRefs.Count -eq 2 -and (-not $row[1] -or $erpRefs -contains $row[1]))

Write-Result $dbA "resend: $($resend.HttpStatus) $($resend.Status); ilk POST: $($post.HttpStatus) ($($post.Seconds) sn); satır: $($row[0])"

# ---------------------------------------------------------------- B
Write-Title "Ek 1-B) Aynı faturaya aynı anda $Parallel resend: send_attempt_count kaybı var mı"

Restart-Simulator @{
    Simulator__Rates__Success       = 0
    Simulator__Rates__Busy          = 100
    Simulator__Rates__ServerError   = 0
    Simulator__Rates__SaveThenError = 0
    Simulator__Rates__LateResponse  = 0
}
Wait-Service

Write-Step 'Fatura oluşturuluyor (Busy %100: Başarısız kalır, resend edilebilir)'
$first = New-ServiceInvoice
Write-ServiceResult $first
$b = $first.InvoiceNumber

Write-Step "$Parallel resend aynı anda gönderiliyor"
$tasks = 1..$Parallel | ForEach-Object { $script:Http.PostAsync("$ServiceUrl/api/v1/invoices/$b/resend", $null) }
[System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tasks)
$codes = ($tasks | ForEach-Object { [int]$_.Result.StatusCode } | Group-Object | ForEach-Object { "$($_.Name) x $($_.Count)" }) -join ', '
Write-Host "  Cevaplar: $codes"

$posts = @(Get-SimulatorLog | Where-Object { $_ -match "ERP request #\d+ invoice=$b behavior=" }).Count
$expected = 1 + $Parallel

Write-DbHeader "Ek 1-B: sayaç gerçek gönderim sayısına eşit mi" "Fatura numarası: $b"
Show-ServiceQuery "SELECT invoice_number, status, erp_reference, last_error, send_attempt_count FROM invoices WHERE invoice_number = '$b';"
Show-ErpQuery "SELECT count(*) AS kayit FROM invoices WHERE invoice_number = '$b';"
Write-Host '  (Busy kayıt açmadığı için simülatör veritabanında 0 kayıt beklenir; gönderim sayısı simülatör logundan sayılır.)' -ForegroundColor DarkGray
Write-Host "  Simülatör logundaki POST sayısı (invoice=$b): $posts" -ForegroundColor DarkGray

$count = [int]@(Get-ServiceRows "SELECT send_attempt_count FROM invoices WHERE invoice_number = '$b';")[0]
Write-Host ''
$dbB = Write-DbVerdict "send_attempt_count = simülatörün gördüğü POST sayısı = $expected (1 + $Parallel)" `
    "send_attempt_count = $count, simülatörün gördüğü POST = $posts" ($count -eq $expected -and $posts -eq $expected)

Write-Result $dbB "cevaplar: $codes; sayaç $count / gerçek gönderim $posts"

Restart-Simulator
