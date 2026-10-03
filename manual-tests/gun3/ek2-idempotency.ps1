# Gün 3 - Ek test 2 (QA bulgusu F1): simülatörün Simulator:IdempotentInvoices ayarı. Kontrol listesinin parçası değil. ~3 dk.
#
#   A) Ayar kapalı (varsayılan), Success %100: aynı fatura simülatöre doğrudan iki kez gönderilir -> iki kayıt, iki farklı
#      referans (Gün 1'deki davranış değişmedi).
#   B) Ayar açık, Success %100: aynı fatura iki kez -> ikisi de 202, aynı referans, simülatörde tek kayıt (ikincisi logda
#      behavior=Duplicate). Aynı numara farklı tutarla -> 409, kayıt sayısı yine 1.
#   C) F1, Fatura Servisi üzerinden: simülatörün kendi veritabanı kaydı çok geç tamamlıyor. Bunu kurmak için simülatörün
#      invoices tablosu SHARE modunda kilitlenir: okumalar (GET) çalışır, yeni kayıt (INSERT) kilit bırakılana kadar bekler.
#      1. deneme: POST'un kaydı bekler, servis 10 sn'de vazgeçer. 2. deneme: servis önce sorar, GET 404 döner (kayıt
#      henüz yok), yeniden POST yapar. Simülatörde iki isteğin de beklediği görülünce kilit bırakılır.
#        C1) Ayar kapalı: iki istek de kaydedilir -> simülatörde 2 kayıt. Servisin tek başına kesin önleyemediği durum
#            (beklenen sonuç bu; sınırın gerçekten var olduğunu gösterir).
#        C2) Ayar açık: ikinci istek birincinin kaydını bekler, onu bulur -> simülatörde 1 kayıt, servisteki referans aynı.
#
# Sonunda simülatör varsayılan ayarlarına (ayar kapalı) döner.
. "$PSScriptRoot\_common.ps1"

$LockApp = 'ek2-lock'

# Kilidi tutan psql oturumunu sonlandırır (transaction geri alınır, kilit bırakılır). Oturum yoksa bir şey yapmaz.
function Stop-TableLock {
    Get-ErpRows "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = '$LockApp';" | Out-Null
    Get-Job -Name $LockApp -ErrorAction SilentlyContinue | Remove-Job -Force
}

# Script bir hatayla yarıda kesilirse kilit açık, simülatör değiştirilmiş ayarda kalıp sonraki testleri bozmasın.
trap { Write-Host "Hata: $_ - kilit bırakılıyor, simülatör varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Stop-TableLock } catch { }; try { Restart-Simulator } catch { }; break }

Write-Title 'Ek 2) Simülatörde IdempotentInvoices ayarı: kapalıyken iki kayıt, açıkken tek kayıt (F1)'

$success = @{ Simulator__Rates__Success = 100; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0
              Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0 }

function Send-InvoiceAmount([string]$InvoiceNumber, [string]$Amount) {
    $json = '{"invoiceNumber":"' + $InvoiceNumber + '","customerCode":"C-001","amount":' + $Amount + ',"currency":"TRY","invoiceDate":"2026-09-29"}'
    $content = New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')
    $response = $script:Http.PostAsync("$SimulatorUrl/api/v1/invoices", $content).GetAwaiter().GetResult()
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $reference = if ($body -match '"erpReference":"([^"]+)"') { $Matches[1] } else { '-' }
    Write-Host ('  POST {0} amount={1,-8} -> {2}  erpReference={3}' -f $InvoiceNumber, $Amount, [int]$response.StatusCode, $reference)
    [pscustomobject]@{ Status = [int]$response.StatusCode; Reference = $reference }
}

function Get-ErpRefs([string]$Number) {
    @(Get-ErpRows "SELECT erp_reference FROM invoices WHERE invoice_number = '$Number' ORDER BY id;")
}

# C) bölümü: simülatör tablosunu kilitler, servis üzerinden 1 fatura oluşturur, iki isteğin beklediğini görünce
# kilidi bırakır, kuyruğun boşalmasını bekler; faturanın son durumunu döner.
function Invoke-SlowSave([string]$Title) {
    Write-Step "$Title - simülatörün invoices tablosu SHARE modunda kilitleniyor (okuma serbest, yeni kayıt bekler)"
    Start-Job -Name $LockApp -ArgumentList $RepoRoot, $LockApp -ScriptBlock {
        param($root, $app)
        Set-Location $root
        & docker compose exec -T -e "PGAPPNAME=$app" erp-db psql -U erp -d erp_simulator `
            -c 'BEGIN; LOCK TABLE invoices IN SHARE MODE; SELECT pg_sleep(180); COMMIT;' 2>&1 | Out-Null
    } | Out-Null

    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ([int]@(Get-ErpRows ("SELECT count(*) FROM pg_locks l JOIN pg_class c ON c.oid = l.relation " +
                               "WHERE c.relname = 'invoices' AND l.mode = 'ShareLock' AND l.granted;"))[0] -eq 0) {
        if ($watch.Elapsed.TotalSeconds -gt 30) { throw 'Tablo kilidi 30 sn içinde alınamadı.' }
        Start-Sleep -Milliseconds 250
    }
    Write-Host '  Kilit alındı.'

    $number = (New-ServiceInvoices 1).From
    Write-Step "$number için iki isteğin simülatörde beklemesi bekleniyor (1. deneme ~10 sn'de zaman aşımı, 2. deneme GET 404 + POST)"
    $watch.Restart()
    while ($true) {
        $waiting = [int]@(Get-ErpRows ("SELECT count(*) FROM pg_stat_activity WHERE datname = 'erp_simulator' " +
                                       "AND wait_event_type = 'Lock' AND application_name <> '$LockApp';"))[0]
        if ($waiting -ge 2) { break }
        if ($watch.Elapsed.TotalSeconds -gt 60) { throw "60 sn içinde iki bekleyen istek görülmedi (bekleyen: $waiting)." }
        Start-Sleep -Milliseconds 250
    }
    Write-Host ('  {0:N1} sn sonra simülatörde 2 istek bekliyor. Kilit bırakılıyor.' -f $watch.Elapsed.TotalSeconds)
    Stop-TableLock
    Wait-QueueDrained $number $number 120 | Out-Null

    Write-Step "Servis logu ($number)"
    Get-ServiceLog | Where-Object { $_ -match "ERP send( start)? invoice=$number " } |
        ForEach-Object { Write-Host ('  ' + ($_ -replace ' info: InvoiceService\.Application\.Outbox\.OutboxProcessor\[0\]', '' -replace ' erpReference=.*$', '')) }
    Write-Step "Simülatör logu ($number)"
    Get-SimulatorLog | Where-Object { $_ -match "invoice=$number " } | ForEach-Object { Write-Host "  $_" }

    Write-DbHeader $Title "Fatura numarası: $number"
    Show-ServiceQuery "SELECT invoice_number, status, erp_reference, send_attempt_count FROM invoices WHERE invoice_number = '$number';"
    Show-ErpQuery "SELECT id, invoice_number, erp_reference, behavior, received_at FROM invoices WHERE invoice_number = '$number' ORDER BY id;"

    $row = @(Get-ServiceRows "SELECT status, coalesce(erp_reference, '-') FROM invoices WHERE invoice_number = '$number';")[0] -split '\|'
    [pscustomobject]@{ Number = $number; Status = $row[0]; Reference = $row[1]; ErpRefs = @(Get-ErpRefs $number)
                       Duplicates = @(Get-SimulatorLog | Where-Object { $_ -match "invoice=$number behavior=Duplicate" }).Count }
}

Wait-Service
$allPassed = $true
$prefix = New-Prefix 'E2'

# --- A) Ayar kapalı: Gün 1 davranışı -------------------------------------------------------------------------------
$settings = $success.Clone(); $settings.Simulator__IdempotentInvoices = 'false'
Restart-Simulator $settings
$n = "${prefix}A"
Write-Step "A) Ayar kapalı: $n iki kez gönderiliyor"
$r1 = Send-InvoiceAmount $n '1250.50'
$r2 = Send-InvoiceAmount $n '1250.50'
$refs = @(Get-ErpRefs $n)
Write-DbHeader 'A) Ayar kapalı' "Fatura numarası: $n"
Show-ErpQuery "SELECT id, invoice_number, erp_reference, behavior FROM invoices WHERE invoice_number = '$n' ORDER BY id;"
$ok = Write-DbVerdict 'iki istek de 202; simülatörde 2 kayıt, referanslar farklı (Gün 1 davranışı)' `
    "$($r1.Status) / $($r2.Status); simülatörde $($refs.Count) kayıt: $($refs -join ', ')" `
    ($r1.Status -eq 202 -and $r2.Status -eq 202 -and $refs.Count -eq 2 -and $refs[0] -ne $refs[1])
$allPassed = $allPassed -and $ok

# --- B) Ayar açık: aynı içerik tek kayıt, farklı içerik 409 --------------------------------------------------------
$settings = $success.Clone(); $settings.Simulator__IdempotentInvoices = 'true'
Restart-Simulator $settings
$n = "${prefix}B"
Write-Step "B) Ayar açık: $n iki kez aynı içerikle, sonra farklı tutarla gönderiliyor"
$r1 = Send-InvoiceAmount $n '1250.50'
$r2 = Send-InvoiceAmount $n '1250.50'
$r3 = Send-InvoiceAmount $n '999.00'
$refs = @(Get-ErpRefs $n)
$dup = @(Get-SimulatorLog | Where-Object { $_ -match "invoice=$n behavior=Duplicate" }).Count
Write-DbHeader 'B) Ayar açık' "Fatura numarası: $n"
Show-ErpQuery "SELECT id, invoice_number, erp_reference, amount, behavior FROM invoices WHERE invoice_number = '$n' ORDER BY id;"
$ok = Write-DbVerdict 'ilk iki istek 202 ve aynı referans, farklı tutar 409; simülatörde 1 kayıt; logda 1 Duplicate' `
    "$($r1.Status) $($r1.Reference) / $($r2.Status) $($r2.Reference) / $($r3.Status); simülatörde $($refs.Count) kayıt; Duplicate $dup" `
    ($r1.Status -eq 202 -and $r2.Status -eq 202 -and $r1.Reference -eq $r2.Reference -and $r3.Status -eq 409 -and
     $refs.Count -eq 1 -and $refs[0] -eq $r1.Reference -and $dup -eq 1)
$allPassed = $allPassed -and $ok

# --- C) F1: kaydı geç tamamlanan istek, servis üzerinden -----------------------------------------------------------
$settings = $success.Clone(); $settings.Simulator__IdempotentInvoices = 'false'
Restart-Simulator $settings
$c1 = Invoke-SlowSave 'C1) Ayar kapalı, kayıt geç tamamlanıyor'
$ok = Write-DbVerdict 'fatura Gönderildi; simülatörde 2 kayıt (servisin tek başına kesin önleyemediği çift kayıt)' `
    "fatura $($c1.Status) $($c1.Reference); simülatörde $($c1.ErpRefs.Count) kayıt: $($c1.ErpRefs -join ', ')" `
    ($c1.Status -eq 'Gönderildi' -and $c1.ErpRefs.Count -eq 2)
$allPassed = $allPassed -and $ok

$settings = $success.Clone(); $settings.Simulator__IdempotentInvoices = 'true'
Restart-Simulator $settings
$c2 = Invoke-SlowSave 'C2) Ayar açık, kayıt geç tamamlanıyor'
$ok = Write-DbVerdict 'fatura Gönderildi; simülatörde 1 kayıt, referans servistekiyle aynı; logda 1 Duplicate' `
    "fatura $($c2.Status) $($c2.Reference); simülatörde $($c2.ErpRefs.Count) kayıt: $($c2.ErpRefs -join ', '); Duplicate $($c2.Duplicates)" `
    ($c2.Status -eq 'Gönderildi' -and $c2.ErpRefs.Count -eq 1 -and $c2.ErpRefs[0] -eq $c2.Reference -and $c2.Duplicates -eq 1)
$allPassed = $allPassed -and $ok

Restart-Simulator
Write-Result $allPassed "Ayar kapalıyken Gün 1 davranışı ve F1 çift kaydı görülüyor; açıkken aynı fatura tek kayıt ($($c1.Number), $($c2.Number))"
