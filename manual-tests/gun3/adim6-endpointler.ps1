# Gün 3 - Adım 6: endpoint değişiklikleri (kontrol listesinin parçası değil, adımın kendi testi). ~1 dk.
#
#   A) GET /api/v1/invoices?status=...: her durum için dönen fatura sayısı veritabanındakiyle aynı; durum verilmezse hepsi;
#      geçersiz durum 400.
#   B) resend kuralları: olmayan fatura 404; Gönderildi ve Bekliyor fatura 409; hiçbirinde veritabanı değişmiyor.
#   C) resend simülatöre gitmiyor, yalnızca kuyruğa alıyor (202, Bekliyor). Simülatör Success %100 iken:
#      C1) Adım 3'te zaman aşımıyla Başarısız kalmış ama simülatörde kayıtlı bir fatura: worker "found" der, POST yok,
#          fatura simülatördeki referansla Gönderildi, simülatörde hâlâ 1 kayıt.
#      C2) Gün 2'den kalan, outbox kaydı olmayan ve simülatörde olmayan Başarısız bir fatura: resend outbox kaydını
#          oluşturur, worker "notFound" -> POST -> Gönderildi, simülatörde 1 kayıt.
#   D) Aynı Başarısız faturaya aynı anda iki resend: biri 202, diğeri 409.
# C ve D'de kullanılacak faturalar veritabanından seçilir; bulunamazsa script durur (önce adim3-worker.ps1 çalıştırılmalı).
. "$PSScriptRoot\_common.ps1"

Write-Title 'Adım 6) resend yalnızca kuyruğa alıyor; GET /api/v1/invoices?status=... ile listeleme'

Write-Step 'Fatura Servisi yeni kodla derlenip yeniden başlatılıyor...'
Invoke-Compose @('up', '-d', '--build', 'invoice-service')
Wait-Service
Restart-Simulator @{ Simulator__Rates__Success = 100; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0
                     Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0 }
# Açılışta kuyrukta bekleyen başka faturalar varsa (önceki testlerden) bitsin ki sayımlar kıpırdamasın.
Wait-QueueDrained 'FTR-000000' 'FTR-999999' 120 | Out-Null

$allPassed = $true

function Get-Json([string]$Url) {
    $response = $script:Http.GetAsync($Url).GetAwaiter().GetResult()
    [pscustomobject]@{ Status = [int]$response.StatusCode; Body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
}

# --- A) Listeleme -------------------------------------------------------------------------------------------------
Write-Step 'A) GET /api/v1/invoices?status=...'
Write-DbHeader 'A) Endpoint''in döndürdüğü sayılar veritabanındakiyle aynı mı' ''
Show-ServiceQuery 'SELECT status, count(*) AS fatura FROM invoices GROUP BY 1 ORDER BY 1;'
$listOk = $true
foreach ($status in 'Bekliyor', 'Gönderildi', 'Başarısız', '') {
    $url = if ($status) { "$ServiceUrl/api/v1/invoices?status=$([Uri]::EscapeDataString($status))" } else { "$ServiceUrl/api/v1/invoices" }
    $r = Get-Json $url
    # Parantez şart: Windows PowerShell 5.1'de ConvertFrom-Json diziyi tek nesne olarak verir, @() onu açmaz.
    $items = @(($r.Body | ConvertFrom-Json) | ForEach-Object { $_ })
    $where = if ($status) { "WHERE status = '$status'" } else { '' }
    $dbCount = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices $where;")[0]
    $wrong = if ($status) { @($items | Where-Object { $_.status -ne $status }).Count } else { 0 }
    $label = if ($status) { "status=$status" } else { '(durum yok)' }
    $ok = Write-DbVerdict "$label -> 200, $dbCount fatura (veritabanı), hepsi bu durumda" "$($r.Status), $($items.Count) fatura, farklı durumda $wrong" `
        ($r.Status -eq 200 -and $items.Count -eq $dbCount -and $wrong -eq 0)
    $listOk = $listOk -and $ok
}
$r = Get-Json "$ServiceUrl/api/v1/invoices?status=Tamamlandi"
Write-Host "  status=Tamamlandi -> HTTP $($r.Status)  $($r.Body)"
$ok = Write-DbVerdict 'geçersiz durum -> 400' "$($r.Status)" ($r.Status -eq 400)
$allPassed = $allPassed -and $listOk -and $ok

# --- B) resend kuralları ------------------------------------------------------------------------------------------
Write-Step 'B) resend: 404 / 409'
$sentInvoice = @(Get-ServiceRows "SELECT invoice_number FROM invoices WHERE status = 'Gönderildi' ORDER BY invoice_number DESC LIMIT 1;")[0]
# Yeni fatura: resend geldiğinde Bekliyor'dur ya da worker onu o arada göndermiştir; ikisinde de 409. Worker durumunu
# değiştirebileceği için bu satırda yalnızca 409 kontrol edilir.
$pending = New-ServiceInvoice
$cases = @(
    @{ Name = 'olmayan fatura';       Number = 'FTR-999999';  Expected = 404; Unchanged = $true }
    @{ Name = 'Gönderildi fatura';    Number = $sentInvoice;   Expected = 409; Unchanged = $true }
    @{ Name = 'yeni oluşan fatura';   Number = $pending.InvoiceNumber; Expected = 409; Unchanged = $false }
)
foreach ($case in $cases) {
    $before = @(Get-ServiceRows "SELECT status || '|' || coalesce(erp_reference, '-') FROM invoices WHERE invoice_number = '$($case.Number)';")
    $r = Send-ServiceResend $case.Number
    $after = @(Get-ServiceRows "SELECT status || '|' || coalesce(erp_reference, '-') FROM invoices WHERE invoice_number = '$($case.Number)';")
    Write-Host "  $($case.Name) ($($case.Number)) -> HTTP $($r.HttpStatus)  $($r.Body)"
    $expected = if ($case.Unchanged) { "$($case.Expected), fatura değişmedi" } else { "$($case.Expected)" }
    $ok = Write-DbVerdict $expected "$($r.HttpStatus), önce '$($before -join '')' sonra '$($after -join '')'" `
        ($r.HttpStatus -eq $case.Expected -and (-not $case.Unchanged -or ($before -join '') -eq ($after -join '')))
    $allPassed = $allPassed -and $ok
}

# --- C) resend akışı ----------------------------------------------------------------------------------------------
function Show-InvoiceState([string]$Title, [string]$Number) {
    Write-DbHeader $Title "Fatura numarası: $Number"
    Show-ServiceQuery "SELECT invoice_number, status, erp_reference, send_attempt_count, last_error FROM invoices WHERE invoice_number = '$Number';"
    Show-ServiceQuery "SELECT invoice_number, status, attempt_count, next_attempt_at, processed_at, last_error FROM erp_outbox WHERE invoice_number = '$Number';"
    Show-ErpQuery "SELECT id, invoice_number, erp_reference, behavior, received_at FROM invoices WHERE invoice_number = '$Number' ORDER BY id;"
}

# C1: outbox'ı Başarısız (zaman aşımı) ve simülatörde tam 1 kaydı olan bir fatura.
$candidates = @(Get-ServiceRows ("SELECT invoice_number FROM invoices i JOIN erp_outbox o USING (invoice_number) " +
    "WHERE i.status = 'Başarısız' AND o.status = 'Başarısız' AND o.last_error LIKE '%zaman aşımı%' ORDER BY 1 LIMIT 50;"))
$inErp = if ($candidates) { @(Get-ErpRows ("SELECT invoice_number FROM invoices WHERE invoice_number IN ('" + ($candidates -join "','") + "') " +
    "GROUP BY 1 HAVING count(*) = 1 ORDER BY 1;")) } else { @() }
if ($inErp.Count -lt 2) { throw 'C1/D için zaman aşımıyla Başarısız kalmış ve simülatörde kayıtlı 2 fatura bulunamadı; önce .\manual-tests\gun3\adim3-worker.ps1 çalıştırın.' }
$c1 = $inErp[0]
$d = $inErp[1]

# C2: outbox kaydı olmayan (Gün 2'den), simülatörde hiç kaydı olmayan Başarısız bir fatura.
$candidates = @(Get-ServiceRows ("SELECT invoice_number FROM invoices i WHERE status = 'Başarısız' " +
    "AND NOT EXISTS (SELECT 1 FROM erp_outbox o WHERE o.invoice_number = i.invoice_number) ORDER BY 1 DESC LIMIT 50;"))
$present = if ($candidates) { @(Get-ErpRows ("SELECT DISTINCT invoice_number FROM invoices WHERE invoice_number IN ('" + ($candidates -join "','") + "');")) } else { @() }
$c2 = @($candidates | Where-Object { $present -notcontains $_ })[0]
if (-not $c2) { throw 'C2 için Gün 2''den kalan, simülatörde olmayan Başarısız bir fatura bulunamadı.' }

foreach ($case in @(
        @{ Name = 'C1) Simülatörde zaten kayıtlı Başarısız fatura'; Number = $c1; Check = 'found';    Posts = 0 }
        @{ Name = 'C2) Outbox kaydı olmayan, simülatörde olmayan Başarısız fatura (Gün 2)'; Number = $c2; Check = 'notFound'; Posts = 1 })) {
    $number = $case.Number
    Write-Step "$($case.Name): $number"
    Show-InvoiceState "$($case.Name) - resend öncesi" $number
    $postsBefore = @(Get-SimulatorLog | Where-Object { $_ -match "ERP request #\d+ invoice=$number behavior=" }).Count
    $erpBefore = [int]@(Get-ErpRows "SELECT count(*) FROM invoices WHERE invoice_number = '$number';")[0]

    $r = Send-ServiceResend $number
    Write-Host "  resend -> HTTP $($r.HttpStatus), status $($r.Status), süre $($r.Seconds) sn"
    Wait-QueueDrained $number $number 60 | Out-Null

    Show-InvoiceState "$($case.Name) - kuyruk boşaldıktan sonra" $number
    $attempt = @(Get-SendAttempts @($number))[-1]
    $postsAfter = @(Get-SimulatorLog | Where-Object { $_ -match "ERP request #\d+ invoice=$number behavior=" }).Count
    $state = @(Get-ServiceRows ("SELECT i.status, coalesce(i.erp_reference, '-'), o.status, o.attempt_count FROM invoices i " +
        "JOIN erp_outbox o USING (invoice_number) WHERE invoice_number = '$number';"))[0] -split '\|'
    $erpRefs = @(Get-ErpRows "SELECT erp_reference FROM invoices WHERE invoice_number = '$number' ORDER BY id;")
    Write-Host ''
    $ok = Write-DbVerdict ("resend 202 Bekliyor (simülatöre gitmeden); worker '$($case.Check)', simülatöre $($case.Posts) POST; fatura Gönderildi, " +
        'outbox Tamamlandı (1 deneme); simülatörde 1 kayıt ve referansı faturadakiyle aynı') `
        ("resend $($r.HttpStatus) $($r.Status); worker '$($attempt.Check)', $($postsAfter - $postsBefore) POST; fatura $($state[0]), " +
         "outbox $($state[2]) ($($state[3]) deneme); simülatörde $erpBefore -> $($erpRefs.Count) kayıt, referans $($state[1]) / $($erpRefs -join ',')") `
        ($r.HttpStatus -eq 202 -and $r.Status -eq 'Bekliyor' -and $attempt.Check -eq $case.Check -and ($postsAfter - $postsBefore) -eq $case.Posts -and
         $state[0] -eq 'Gönderildi' -and $state[2] -eq 'Tamamlandı' -and $state[3] -eq '1' -and $erpRefs.Count -eq 1 -and $erpRefs[0] -eq $state[1])
    $allPassed = $allPassed -and $ok
}

# --- D) Aynı anda iki resend ---------------------------------------------------------------------------------------
Write-Step "D) Aynı Başarısız faturaya aynı anda iki resend: $d"
$tasks = 1..2 | ForEach-Object { $script:Http.PostAsync("$ServiceUrl/api/v1/invoices/$d/resend", $null) }
$codes = @($tasks | ForEach-Object { [int]$_.GetAwaiter().GetResult().StatusCode } | Sort-Object)
Write-Host "  HTTP: $($codes -join ', ')"
Wait-QueueDrained $d $d 60 | Out-Null
$erpCount = [int]@(Get-ErpRows "SELECT count(*) FROM invoices WHERE invoice_number = '$d';")[0]
$status = @(Get-ServiceRows "SELECT status FROM invoices WHERE invoice_number = '$d';")[0]
Write-DbHeader 'D) İki resend' "Fatura numarası: $d"
Show-ServiceQuery "SELECT invoice_number, status, erp_reference, send_attempt_count FROM invoices WHERE invoice_number = '$d';"
Show-ErpQuery "SELECT invoice_number, count(*) AS kayit FROM invoices WHERE invoice_number = '$d' GROUP BY 1;"
$ok = Write-DbVerdict 'biri 202, diğeri 409; fatura Gönderildi; simülatörde 1 kayıt' "$($codes -join ' ve '); fatura $status; simülatörde $erpCount kayıt" `
    (($codes -join ',') -eq '202,409' -and $status -eq 'Gönderildi' -and $erpCount -eq 1)
$allPassed = $allPassed -and $ok

Restart-Simulator

Write-Result $allPassed 'GET ?status= doğru listeliyor; resend yalnızca Başarısız faturayı kuyruğa alıyor, simülatöre kendisi gitmiyor, çift kayıt oluşmuyor'
