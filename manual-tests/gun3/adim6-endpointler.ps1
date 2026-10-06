# Gün 3 - Adım 6: endpoint değişiklikleri (kontrol listesinin parçası değil, adımın kendi testi). ~6 dk.
#
#   A) GET /api/v1/invoices?status=...: her durum için dönen fatura sayısı veritabanındakiyle aynı; durum verilmezse hepsi;
#      geçersiz durum 400.
#   B) resend kuralları: olmayan fatura 404; Gönderildi ve Bekliyor fatura 409; hiçbirinde veritabanı değişmiyor.
#   C) "Başarısız ama simülatörde kayıtlı" bir faturaya aynı anda iki resend:
#      - biri 202 (fatura Bekliyor, resend simülatöre kendisi gitmiyor), diğeri 409;
#      - worker faturayı simülatörde bulur ("found"): tekrar POST yok, fatura simülatördeki referansla Gönderildi,
#        simülatörde hâlâ tek kayıt.
#      Başlangıç durumu veritabanına dokunmadan, gerçekte olabileceği gibi üretilir: fatura 9 kez ServerError alır;
#      10. denemede simülatör LateResponse'tadır (isteği alınca kaydeder, cevap vermez); servis 10 sn'de vazgeçip
#      Başarısız demeden önce simülatöre son kez sorar, ama simülatör o arada öldürülmüştür ("sorulamadı"). Fatura serviste
#      Başarısız, simülatörün veritabanında kayıtlı kalır.
. "$PSScriptRoot\_common.ps1"
# Script bir hatayla yarıda kesilirse simülatör öldürülmüş ya da değiştirilmiş ayarda kalıp sonraki testleri bozmasın:
# varsayılan ayarlarına döndürülür, hata yine yukarı iletilir.
trap { Write-Host "Hata: $_ - simülatör varsayılan ayarlarına döndürülüyor." -ForegroundColor Red; try { Restart-Simulator } catch { }; break }

Write-Title 'Adım 6) resend yalnızca kuyruğa alıyor; GET /api/v1/invoices?status=... ile listeleme'

Write-Step 'Fatura Servisi yeni kodla derlenip yeniden başlatılıyor...'
Invoke-Compose @('up', '-d', '--build', 'invoice-service')
Wait-Service
Restart-Simulator @{ Simulator__Rates__Success = 100; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0
                     Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0 }
# Açılışta kuyrukta bekleyen başka faturalar varsa (önceki testlerden) bitsin ki sayımlar kıpırdamasın.
Wait-QueueDrained 'FTR-000000' 'FTR-999999' 120 | Out-Null

$allPassed = $true

# Liste sayfalıdır: bütün sayfaların satırları ({items, totalPages, ...}) toplanır; HTTP kodu ilk sayfanınkidir.
function Get-AllPages([string]$Query) {
    $all = @(); $page = 1; $status = 0
    do {
        $sep = if ($Query) { '&' } else { '' }
        $r = Get-Json "$ServiceUrl/api/v1/invoices?$Query${sep}page=$page&pageSize=100"
        if ($page -eq 1) { $status = $r.Status }
        if ($r.Status -ne 200) { break }
        $json = $r.Body | ConvertFrom-Json
        $all += @($json.items)
        $page++
    } while ($page -le $json.totalPages)
    [pscustomobject]@{ Status = $status; Items = $all }
}

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
    $query = if ($status) { "status=$([Uri]::EscapeDataString($status))" } else { '' }
    $r = Get-AllPages $query
    $items = $r.Items
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
# Gönderildi bir fatura: simülatör Success %100'deyken bir fatura oluşturup gönderilmesi beklenir (temiz kurulumda da çalışsın).
$sentInvoice = (New-ServiceInvoices 1).From
Wait-QueueDrained $sentInvoice $sentInvoice 60 | Out-Null
if (@(Get-ServiceRows "SELECT status FROM invoices WHERE invoice_number = '$sentInvoice';")[0] -ne 'Gönderildi') { throw "$sentInvoice Gönderildi olmadı; B bölümü kurulamadı." }
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

# --- C) Başarısız ama simülatörde kayıtlı faturaya aynı anda iki resend ------------------------------------------
function Show-InvoiceState([string]$Title, [string]$Number) {
    Write-DbHeader $Title "Fatura numarası: $Number"
    Show-ServiceQuery "SELECT invoice_number, status, erp_reference, send_attempt_count, last_error FROM invoices WHERE invoice_number = '$Number';"
    Show-ServiceQuery "SELECT invoice_number, status, attempt_count, processed_at, last_error FROM erp_outbox WHERE invoice_number = '$Number';"
    Show-ErpQuery "SELECT id, invoice_number, erp_reference, behavior, received_at FROM invoices WHERE invoice_number = '$Number' ORDER BY id;"
}

$only = @{ Simulator__Rates__Success = 0; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0
           Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0 }

$settings = $only.Clone(); $settings.Simulator__Rates__ServerError = 100
Restart-Simulator $settings
Write-Step 'C) Başlangıç durumu: 1 fatura, 9 deneme ServerError ile tükenene kadar bekleniyor (~4 dk)'
$number = (New-ServiceInvoices 1).From
Wait-NinthAttemptDone $number
Write-Host "  $number 9. denemeyi bitirdi. Simülatör LateResponse %100'e alınıyor (isteği kaydeder, 30 sn cevap vermez)."
$settings = $only.Clone(); $settings.Simulator__Rates__LateResponse = 100
Restart-Simulator $settings

Write-Step '10. denemenin simülatöre ulaşması bekleniyor'
$watch = [Diagnostics.Stopwatch]::StartNew()
while ([int]@(Get-ErpRows "SELECT count(*) FROM invoices WHERE invoice_number = '$number';")[0] -lt 1) {
    if ($watch.Elapsed.TotalSeconds -gt 120) { throw "$number 10. denemesi 120 sn içinde simülatöre ulaşmadı." }
    Start-Sleep -Milliseconds 250
}
Write-Host "  10. deneme simülatöre ulaştı ve kaydedildi; servis cevabı bekliyor (10 sn'de zaman aşımı)."
Write-Step 'Simülatör öldürülüyor (docker kill): servisin son kontrolü simülatöre ulaşamayacak'
Invoke-Compose @('kill', 'erp-simulator')
Wait-QueueDrained $number $number 60 | Out-Null

Show-InvoiceState 'C) Başlangıç durumu: serviste Başarısız, simülatörde kayıtlı' $number
$before = @(Get-ServiceRows "SELECT i.status, o.status, coalesce(i.last_error, '') FROM invoices i JOIN erp_outbox o USING (invoice_number) WHERE invoice_number = '$number';")[0] -split '\|'
$erpBefore = [int]@(Get-ErpRows "SELECT count(*) FROM invoices WHERE invoice_number = '$number';")[0]
Write-Host ''
$setupOk = Write-DbVerdict 'fatura ve outbox Başarısız, hata "Son durum ERP''ye sorulamadı"; simülatörde 1 kayıt' `
    "fatura $($before[0]), outbox $($before[1]); hata: $($before[2]); simülatörde $erpBefore kayıt" `
    ($before[0] -eq 'Başarısız' -and $before[1] -eq 'Başarısız' -and $before[2] -match 'sorulamadı' -and $erpBefore -eq 1)
if (-not $setupOk) { throw 'Başlangıç durumu kurulamadı (zamanlama); testi yeniden çalıştırın.' }

Restart-Simulator @{ Simulator__Rates__Success = 100; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0
                     Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0 }
Write-Step "Aynı faturaya aynı anda iki resend: $number"
$tasks = 1..2 | ForEach-Object { $script:Http.PostAsync("$ServiceUrl/api/v1/invoices/$number/resend", $null) }
$responses = @($tasks | ForEach-Object { $_.GetAwaiter().GetResult() })
$codes = @($responses | ForEach-Object { [int]$_.StatusCode } | Sort-Object)
$acceptedBody = ($responses | Where-Object { [int]$_.StatusCode -eq 202 } | Select-Object -First 1)
$acceptedStatus = if ($acceptedBody) { ($acceptedBody.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json).status } else { '-' }
Write-Host "  HTTP: $($codes -join ', '); kabul edilenin cevabındaki durum: $acceptedStatus"
Wait-QueueDrained $number $number 60 | Out-Null

Show-InvoiceState 'C) İki resend sonrası' $number
$attempt = @(Get-SendAttempts @($number))[-1]
$postsAfter = @(Get-SimulatorLog | Where-Object { $_ -match "ERP request #\d+ invoice=$number behavior=" }).Count
$state = @(Get-ServiceRows ("SELECT i.status, coalesce(i.erp_reference, '-'), o.status, o.attempt_count FROM invoices i " +
    "JOIN erp_outbox o USING (invoice_number) WHERE invoice_number = '$number';"))[0] -split '\|'
$erpRefs = @(Get-ErpRows "SELECT erp_reference FROM invoices WHERE invoice_number = '$number' ORDER BY id;")
Write-Host ''
$ok = Write-DbVerdict ("resend'lerden biri 202 (Bekliyor), diğeri 409; worker 'found', simülatör yeniden başlatıldıktan sonra 0 POST; " +
    'fatura Gönderildi, outbox Tamamlandı (resend sonrası 1 deneme); simülatörde 1 kayıt ve referansı faturadakiyle aynı') `
    ("$($codes -join ' ve ') ($acceptedStatus); worker '$($attempt.Check)', $postsAfter POST; fatura $($state[0]), outbox $($state[2]) " +
     "($($state[3]) deneme); simülatörde $($erpRefs.Count) kayıt, referans $($state[1]) / $($erpRefs -join ',')") `
    (($codes -join ',') -eq '202,409' -and $acceptedStatus -eq 'Bekliyor' -and $attempt.Check -eq 'found' -and $postsAfter -eq 0 -and
     $state[0] -eq 'Gönderildi' -and $state[2] -eq 'Tamamlandı' -and $state[3] -eq '1' -and $erpRefs.Count -eq 1 -and $erpRefs[0] -eq $state[1])
$allPassed = $allPassed -and $ok

Restart-Simulator

Write-Result $allPassed 'GET ?status= doğru listeliyor; resend yalnızca Başarısız faturayı kuyruğa alıyor, simülatöre kendisi gitmiyor; simülatörde kayıtlı faturaya resend çift kayıt oluşturmuyor'
