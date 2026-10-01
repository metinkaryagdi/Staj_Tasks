# Gün 3 - Adım 5: çift kayıt koruması (kontrol listesinin parçası değil, adımın kendi testi). ~4 dk.
# Fatura daha önce gönderilmeye çalışıldıysa servis POST'tan önce simülatöre GET ile sorar:
#   found    -> simülatörde zaten var: POST yapılmaz, oradaki erp_reference alınır
#   notFound -> yok: POST yapılır
#   unknown  -> sorulamadı (simülatör kapalı vb.): POST yapılmaz, deneme başarısız sayılır ve backoff ile tekrar denenir
#
#   A) SaveThenError %100, 5 fatura: simülatör kaydedip 500 döner. 2. denemede "found" -> Gönderildi, simülatörde 1 kayıt.
#   B) LateResponse %100, 5 fatura: simülatör kaydeder ama 30 sn bekletir, servis 10 sn'de vazgeçer. 2. denemede "found".
#   C) Simülatör kapalı, 3 fatura: kapalıyken denemeler "unknown" (POST yok); açılınca "notFound" -> POST -> Gönderildi.
#   D) Varsayılan oranlar, 100 fatura: simülatörde birden fazla kaydı olan 0, Gönderildi ama simülatörde olmayan 0,
#      erp_reference farklı olan 0.
# Simülatörde her POST "ERP request #N invoice=... behavior=..." diye loglanır; GET loglanmaz. POST sayısı da gösterilir.
. "$PSScriptRoot\_common.ps1"

Write-Title 'Adım 5) Çift kayıt koruması: tekrar göndermeden önce simülatöre sor'

Write-Step 'Fatura Servisi yeni kodla derlenip yeniden başlatılıyor...'
Invoke-Compose @('up', '-d', '--build', 'invoice-service')
Wait-Service

$allPassed = $true

function Get-Numbers($Range) {
    @(Get-ServiceRows "SELECT invoice_number FROM invoices WHERE invoice_number BETWEEN '$($Range.From)' AND '$($Range.To)' ORDER BY 1;")
}

function Get-PostCount([string[]]$Numbers) {
    @(Get-SimulatorLog | Where-Object { $_ -match 'ERP request #\d+ invoice=(\S+) behavior=' -and $Numbers -contains $Matches[1] }).Count
}

# Fatura ve simülatör karşılaştırması: Gönderildi sayısı, simülatördeki kayıt sayısı, birden fazla kaydı olan, aynı referans.
function Test-Range([string]$Title, $Range, [int]$Count, [string]$ExpectedChecks, [scriptblock]$AttemptsOk, [int]$ExpectedPosts) {
    $numbers = Get-Numbers $Range
    $attempts = @(Get-SendAttempts $numbers)
    Show-SendAttempts $attempts
    $posts = Get-PostCount $numbers

    $where = "invoice_number BETWEEN '$($Range.From)' AND '$($Range.To)'"
    Write-DbHeader $Title "Fatura aralığı: $($Range.From) .. $($Range.To)"
    Show-ServiceQuery "SELECT invoice_number, status, erp_reference, send_attempt_count FROM invoices WHERE $where ORDER BY 1;"
    Show-ErpQuery ("SELECT invoice_number, count(*) AS kayit, string_agg(erp_reference || ' ' || behavior, ', ' ORDER BY id) AS kayitlar " +
        "FROM invoices WHERE $where GROUP BY 1 ORDER BY 1;")
    $sent = @(Get-ServiceRows "SELECT invoice_number || '=' || erp_reference FROM invoices WHERE $where AND status = 'Gönderildi' ORDER BY 1;")
    $erp = @(Get-ErpRows "SELECT invoice_number || '=' || erp_reference FROM invoices WHERE $where ORDER BY 1;")
    $same = @($sent | Where-Object { $erp -contains $_ }).Count
    $attemptsPassed = & $AttemptsOk $attempts
    Write-Host ''
    Write-DbVerdict "$ExpectedChecks; $Count Gönderildi; simülatörde $Count kayıt (her faturadan 1); referanslar aynı; simülatöre $ExpectedPosts POST" `
        "denemeler: $(if ($attemptsPassed) { 'beklendiği gibi' } else { 'BEKLENMEDİK' }); $($sent.Count) Gönderildi; simülatörde $($erp.Count) kayıt; $same aynı; $posts POST" `
        ($attemptsPassed -and $sent.Count -eq $Count -and $erp.Count -eq $Count -and $same -eq $Count -and $posts -eq $ExpectedPosts)
}

$only = @{ Simulator__Rates__Success = 0; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0
           Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0 }

# --- A) SaveThenError ---------------------------------------------------------------------------------------------
$settings = $only.Clone(); $settings.Simulator__Rates__SaveThenError = 100
Restart-Simulator $settings
Write-Step 'A) SaveThenError %100: 5 fatura'
$range = New-ServiceInvoices 5
Wait-QueueDrained $range.From $range.To 60 | Out-Null
$ok = Test-Range 'A) SaveThenError: simülatör kaydetti ama 500 döndü' $range 5 `
    'her fatura: 1. deneme first/500, 2. deneme found/Sent' {
        param($a)
        $a.Count -eq 10 -and @($a | Where-Object { $_.Attempt -eq 1 -and $_.Check -eq 'first' -and $_.Http -eq '500' }).Count -eq 5 -and
        @($a | Where-Object { $_.Attempt -eq 2 -and $_.Check -eq 'found' -and $_.Outcome -eq 'Sent' }).Count -eq 5
    } 5
$allPassed = $allPassed -and $ok

# --- B) LateResponse ----------------------------------------------------------------------------------------------
$settings = $only.Clone(); $settings.Simulator__Rates__LateResponse = 100
Restart-Simulator $settings
Write-Step 'B) LateResponse %100: 5 fatura (1. deneme 10 sn''de zaman aşımı)'
$range = New-ServiceInvoices 5
Wait-QueueDrained $range.From $range.To 90 | Out-Null
$ok = Test-Range 'B) LateResponse: simülatör kaydetti, servis 10 sn''de vazgeçti' $range 5 `
    'her fatura: 1. deneme first/zaman aşımı, 2. deneme found/Sent' {
        param($a)
        $a.Count -eq 10 -and @($a | Where-Object { $_.Attempt -eq 1 -and $_.Check -eq 'first' -and $_.Http -eq '-' }).Count -eq 5 -and
        @($a | Where-Object { $_.Attempt -eq 2 -and $_.Check -eq 'found' -and $_.Outcome -eq 'Sent' }).Count -eq 5
    } 5
$allPassed = $allPassed -and $ok

# --- C) Simülatör kapalı -----------------------------------------------------------------------------------------
Write-Step 'C) Simülatör durduruluyor, 3 fatura oluşturuluyor, 20 sn sonra simülatör Success %100 ile açılıyor'
Invoke-Compose @('stop', 'erp-simulator')
$range = New-ServiceInvoices 3
Start-Sleep -Seconds 20
$settings = $only.Clone(); $settings.Simulator__Rates__Success = 100
Restart-Simulator $settings
Wait-QueueDrained $range.From $range.To 90 | Out-Null
$ok = Test-Range 'C) Simülatör kapalıyken: sorulamayınca POST yok' $range 3 `
    'her fatura: 1. deneme first/ulaşılamadı, kapalıyken sonrakiler unknown (POST yok), son deneme notFound/Sent' {
        param($a)
        $byInvoice = $a | Group-Object Invoice
        $byInvoice.Count -eq 3 -and @($byInvoice | Where-Object {
            $list = @($_.Group)
            $list[0].Check -eq 'first' -and $list[0].Http -eq '-' -and $list.Count -ge 3 -and
            @($list[1..($list.Count - 2)] | Where-Object { $_.Check -ne 'unknown' }).Count -eq 0 -and
            $list[-1].Check -eq 'notFound' -and $list[-1].Outcome -eq 'Sent'
        }).Count -eq 3
    } 3
$allPassed = $allPassed -and $ok

# --- D) Varsayılan oranlar ---------------------------------------------------------------------------------------
Restart-Simulator
Write-Step 'D) Varsayılan oranlar: 100 fatura, kuyruk boşalana kadar bekleniyor'
$range = New-ServiceInvoices 100
$seconds = Wait-QueueDrained $range.From $range.To 600
Write-Host "  Kuyruk $seconds sn'de boşaldı."
$http = Compare-Invoices -From $range.From -To $range.To
$numbers = Get-Numbers $range
$attempts = @(Get-SendAttempts $numbers)
$checks = $attempts | Group-Object Check | ForEach-Object { "$($_.Name)=$($_.Count)" }

$where = "invoice_number BETWEEN '$($range.From)' AND '$($range.To)'"
Write-DbHeader 'D) Varsayılan oranlar: çift kayıt ve kayıp' "Fatura aralığı: $($range.From) .. $($range.To)"
Show-ServiceQuery "SELECT status, count(*) AS fatura, round(avg(send_attempt_count), 2) AS ort_deneme, max(send_attempt_count) AS max_deneme FROM invoices WHERE $where GROUP BY 1;"
Show-ErpQuery "SELECT behavior, count(*) AS kayit FROM invoices WHERE $where GROUP BY 1 ORDER BY 1;"
Show-ErpQuery "SELECT invoice_number, count(*) AS kayit FROM invoices WHERE $where GROUP BY 1 HAVING count(*) > 1 ORDER BY 1;"
Write-Host "  Denemelerin kontrol türleri: $($checks -join ', ')" -ForegroundColor DarkGray
$db = Get-DbComparison $range.From $range.To
Write-Host ''
$ok = Write-DbVerdict ('simülatörde birden fazla kaydı olan 0; Gönderildi ama simülatörde olmayan 0; erp_reference farklı olan 0; ' +
    'veritabanından hesaplanan tablo HTTP karşılaştırmasıyla aynı') `
    ("birden fazla kayıt $($db.MultipleRecords); Gönderildi+yok $($db.SentMissing); referans farklı $($db.SentFound - $db.ReferenceMatches); " +
     "tablolar $(if ((Format-Comparison $db) -eq (Format-Comparison $http)) { 'aynı' } else { 'FARKLI' })") `
    ($db.MultipleRecords -eq 0 -and $db.SentMissing -eq 0 -and $db.ReferenceMatches -eq $db.SentFound -and
     (Format-Comparison $db) -eq (Format-Comparison $http))
$allPassed = $allPassed -and $ok

Write-Result $allPassed 'tekrar denemeden önce simülatöre soruluyor: kayıtlıysa POST yok, sorulamazsa POST yok; simülatörde çift kayıt yok'
