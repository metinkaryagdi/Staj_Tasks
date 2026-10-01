# Gün 3 - Adım 4: tekrar deneme kuralları (kontrol listesinin parçası değil, adımın kendi testi). ~8 dk sürer.
#
#   A1) Busy %100 (Retry-After saniye), 3 fatura, 45 sn sonra Success %100: 429'dan sonra planlanan bekleme tam olarak
#       Retry-After kadar, gerçekten geçen süre de o kadar (en fazla ~1 sn fazlası: worker 250 ms'de bir bakıyor).
#       Sonunda hepsi Gönderildi, simülatörde her faturadan tek kayıt (Busy kayıt açmaz).
#   A2) Aynısı Retry-After tarih biçimiyle (HTTP-date): bekleme = tarih - şimdi.
#   B)  ServerError %100, 1 fatura: bekleme 2, 4, 8, 16, 32, sonra 59 (+ 0-1 sn jitter), hiçbiri 60'ı geçmiyor;
#       10. deneme de başarısız olunca fatura ve outbox Başarısız, simülatörde kayıt yok.
# Simülatör yeniden başlatılırken (birkaç sn) gelen denemeler "ulaşılamadı" alır ve backoff ile beklenir; bu normaldir.
# 429 dışındaki 4xx'in hemen Başarısız olması unit testlerde (RetryPolicyTests) kanıtlanıyor: simülatör geçerli bir faturaya 4xx dönmüyor.
. "$PSScriptRoot\_common.ps1"

Write-Title 'Adım 4) Tekrar deneme: 429 -> Retry-After, 500 -> 2/4/8... en fazla 60 sn + jitter, en fazla 10 deneme'

Write-Step 'Fatura Servisi yeni kodla derlenip yeniden başlatılıyor...'
Invoke-Compose @('up', '-d', '--build', 'invoice-service')
Wait-Service
$settingsLine = Get-ServiceLog | Where-Object { $_ -match 'ERP settings:' } | Select-Object -Last 1
Write-Host "  $($settingsLine -replace '^.*ERP settings:', 'Servis ayarları:')" -ForegroundColor DarkGray

$inv = [Globalization.CultureInfo]::InvariantCulture
$allPassed = $true
$busy = @{ Simulator__Rates__Success = 0; Simulator__Rates__Busy = 100; Simulator__Rates__ServerError = 0
           Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0 }
$success = @{ Simulator__Rates__Success = 100; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0
              Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0 }

function Get-Numbers($Range) {
    @(Get-ServiceRows "SELECT invoice_number FROM invoices WHERE invoice_number BETWEEN '$($Range.From)' AND '$($Range.To)' ORDER BY 1;")
}

# --- A) Busy -> Retry-After ---------------------------------------------------------------------------------------
foreach ($format in 'Seconds', 'HttpDate') {
    $title = if ($format -eq 'Seconds') { 'A1) Retry-After saniye' } else { 'A2) Retry-After tarih (HTTP-date)' }
    $settings = $busy.Clone()
    $settings.Simulator__RetryAfterFormat = $format
    Restart-Simulator $settings
    Write-Step "$title`: 3 fatura, 45 sn Busy, sonra Success %100"
    $range = New-ServiceInvoices 3
    Start-Sleep -Seconds 45
    Restart-Simulator $success
    Wait-QueueDrained $range.From $range.To 120 | Out-Null

    $numbers = Get-Numbers $range
    $attempts = @(Get-SendAttempts $numbers)
    Show-SendAttempts $attempts

    # Her 429'dan sonra: plan = Retry-After; sonraki deneme plan kadar (en fazla 1 sn fazlası) sonra başlamış.
    $checked = 0; $bad = @()
    for ($i = 0; $i -lt $attempts.Count - 1; $i++) {
        $a = $attempts[$i]; $next = $attempts[$i + 1]
        if ($a.Http -ne '429' -or $next.Invoice -ne $a.Invoice) { continue }
        $expected = if ($format -eq 'Seconds') { [double]$a.RetryAfter }
                    else { [math]::Max([double]0, ([datetime]::ParseExact($a.RetryAfter, 'r', $inv) - $a.End).TotalSeconds) }
        $checked++
        if ([math]::Abs($a.Wait - $expected) -gt 0.1 -or $next.WaitedBefore -lt $a.Wait - 0.05 -or $next.WaitedBefore -gt $a.Wait + 1) {
            $bad += "$($a.Invoice) #$($a.Attempt): Retry-After $($a.RetryAfter) -> beklenen $([math]::Round($expected, 3)), plan $($a.Wait), geçen $($next.WaitedBefore)"
        }
    }
    $bad | ForEach-Object { Write-Host "  UYUMSUZ: $_" -ForegroundColor Red }

    $where = "invoice_number BETWEEN '$($range.From)' AND '$($range.To)'"
    Write-DbHeader "$title`: sonuç" "Fatura aralığı: $($range.From) .. $($range.To)"
    Show-ServiceQuery "SELECT invoice_number, status, erp_reference, send_attempt_count FROM invoices WHERE $where ORDER BY 1;"
    Show-ServiceQuery "SELECT invoice_number, status, attempt_count, processed_at IS NOT NULL AS bitti FROM erp_outbox WHERE $where ORDER BY 1;"
    Show-ErpQuery "SELECT invoice_number, count(*) AS kayit, string_agg(erp_reference, ',') AS referans FROM invoices WHERE $where GROUP BY 1 ORDER BY 1;"
    $sent = @(Get-ServiceRows "SELECT invoice_number || '=' || erp_reference FROM invoices WHERE $where AND status = 'Gönderildi' ORDER BY 1;")
    $erp = @(Get-ErpRows "SELECT invoice_number || '=' || erp_reference FROM invoices WHERE $where ORDER BY 1;")
    $same = @($sent | Where-Object { $erp -contains $_ }).Count
    Write-Host ''
    $ok = Write-DbVerdict ("429'dan sonraki her denemede plan = Retry-After ve gerçekten o kadar beklendi; 3 fatura Gönderildi, " +
        'simülatörde her birinden 1 kayıt, referanslar aynı') `
        "$checked bekleme ölçüldü, $($bad.Count) uyumsuz; $($sent.Count) Gönderildi, simülatörde $($erp.Count) kayıt, $same referans aynı" `
        ($checked -ge 3 -and $bad.Count -eq 0 -and $sent.Count -eq 3 -and $erp.Count -eq 3 -and $same -eq 3)
    $allPassed = $allPassed -and $ok
}

# --- B) ServerError -> backoff, 10 deneme ---------------------------------------------------------------------------
Restart-Simulator @{ Simulator__Rates__Success = 0; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 100
                     Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0 }
Write-Step 'B) ServerError %100: 1 fatura, 10 deneme tükenene kadar bekleniyor (~5 dk)'
$range = New-ServiceInvoices 1
$seconds = Wait-QueueDrained $range.From $range.To 420
Write-Host "  Fatura $seconds sn sonra Bekliyor'dan çıktı."

$number = $range.From
$attempts = @(Get-SendAttempts @($number))
Show-SendAttempts $attempts

$bases = 2, 4, 8, 16, 32, 59, 59, 59, 59
$bad = @()
for ($i = 0; $i -lt [math]::Min($attempts.Count, 9); $i++) {
    $a = $attempts[$i]; $next = $attempts[$i + 1]
    $jitter = $a.Wait - $bases[$i]
    if ($a.Http -ne '500' -or $jitter -lt 0 -or $jitter -ge 1 -or $a.Wait -gt 60 -or
        -not $next -or $next.WaitedBefore -lt $a.Wait - 0.05 -or $next.WaitedBefore -gt $a.Wait + 1) {
        $bad += "#$($a.Attempt): http $($a.Http), plan $($a.Wait) (taban $($bases[$i])), sonraki $($next.WaitedBefore)"
    }
}
$bad | ForEach-Object { Write-Host "  UYUMSUZ: $_" -ForegroundColor Red }
$last = $attempts[-1]
$maxWait = ($attempts | Measure-Object Wait -Maximum).Maximum

Write-DbHeader 'B) ServerError %100: 10 deneme sonra Başarısız' "Fatura numarası: $number"
Show-ServiceQuery "SELECT invoice_number, status, erp_reference, send_attempt_count, last_error FROM invoices WHERE invoice_number = '$number';"
Show-ServiceQuery "SELECT invoice_number, status, attempt_count, created_at, processed_at, next_attempt_at, locked_until, last_error FROM erp_outbox WHERE invoice_number = '$number';"
Show-ErpQuery "SELECT count(*) AS kayit FROM invoices WHERE invoice_number = '$number';"
$row = @(Get-ServiceRows ("SELECT i.status, i.send_attempt_count, o.status, o.attempt_count, o.processed_at IS NOT NULL, o.locked_until IS NULL " +
    "FROM invoices i JOIN erp_outbox o USING (invoice_number) WHERE invoice_number = '$number';"))[0] -split '\|'
$erpCount = [int]@(Get-ErpRows "SELECT count(*) FROM invoices WHERE invoice_number = '$number';")[0]
Write-Host ''
$ok = Write-DbVerdict ('10 deneme; beklemeler 2/4/8/16/32/59/59/59/59 + 0-1 sn jitter, hiçbiri 60''ı geçmiyor, gerçekten o kadar beklendi; ' +
    'son deneme Failed; fatura ve outbox Başarısız (10 deneme, processed_at dolu, kilit temiz); simülatörde 0 kayıt') `
    ("$($attempts.Count) deneme, $($bad.Count) uyumsuz bekleme, en uzun plan $maxWait sn; son deneme $($last.Outcome); " +
     "fatura $($row[0]) ($($row[1])), outbox $($row[2]) ($($row[3])), processed_at dolu: $($row[4]), kilit temiz: $($row[5]); simülatörde $erpCount kayıt") `
    ($attempts.Count -eq 10 -and $bad.Count -eq 0 -and $maxWait -le 60 -and $last.Outcome -eq 'Failed' -and
     $row[0] -eq 'Başarısız' -and $row[1] -eq '10' -and $row[2] -eq 'Başarısız' -and $row[3] -eq '10' -and $row[4] -eq 't' -and $row[5] -eq 't' -and $erpCount -eq 0)
$allPassed = $allPassed -and $ok

Restart-Simulator

Write-Result $allPassed '429 Retry-After kadar bekliyor (iki biçim), 500 katlanarak artan ve 60 sn''yi geçmeyen jitter''lı beklemeyle, 10 denemede Başarısız'
