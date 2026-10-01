# Gün 3 - Madde 4: ServerError %100 iken 1 fatura gönder. Loglarla bekleme sürelerinin katlanarak arttığını, 60 saniyeyi
# geçmediğini ve onuncu denemeden sonra faturanın Başarısız olduğunu göster. Sonra simülatörü Success %100 ile yeniden
# başlat, resend ile faturanın Gönderildi olduğunu göster. ~6 dk.
#
# Bekleme: 2^n sn (2, 4, 8, 16, 32), sonra 59 sn; her birine 0-1 sn jitter eklenir, toplam hiçbir zaman 60 sn'yi geçmez.
. "$PSScriptRoot\_common.ps1"

Write-Title '4) ServerError %100 -> 1 fatura: katlanarak artan bekleme, 10. denemede Başarısız; sonra resend -> Gönderildi'

Wait-Service
Restart-Simulator @{ Simulator__Rates__Success = 0; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 100
                     Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0 }

Write-Step '1 fatura oluşturuluyor, 10 deneme tükenene kadar bekleniyor (~5 dk)'
$range = New-ServiceInvoices 1
$number = $range.From
$seconds = Wait-QueueDrained $number $number 420
Write-Host "  Fatura $seconds sn sonra Bekliyor'dan çıktı."

Write-Step "Servis logu ($number)"
Get-ServiceLog | Where-Object { $_ -match "ERP send invoice=$number " } |
    ForEach-Object { Write-Host ('  ' + ($_ -replace ' info: InvoiceService\.Outbox\.OutboxProcessor\[0\]', '' -replace ' erpReference=.*$', '')) }

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
$maxWait = ($attempts | Measure-Object Wait -Maximum).Maximum
$last = $attempts[-1]

Write-DbHeader 'Madde 4 - 10 deneme sonra' "Fatura numarası: $number"
Show-ServiceQuery "SELECT invoice_number, status, erp_reference, send_attempt_count, last_error FROM invoices WHERE invoice_number = '$number';"
Show-ServiceQuery "SELECT invoice_number, status, attempt_count, created_at, processed_at, last_error FROM erp_outbox WHERE invoice_number = '$number';"
Show-ErpQuery "SELECT count(*) AS kayit FROM invoices WHERE invoice_number = '$number';"
$row = @(Get-ServiceRows ("SELECT i.status, o.status, o.attempt_count FROM invoices i JOIN erp_outbox o USING (invoice_number) " +
    "WHERE invoice_number = '$number';"))[0] -split '\|'
$erpCount = [int]@(Get-ErpRows "SELECT count(*) FROM invoices WHERE invoice_number = '$number';")[0]
Write-Host ''
$failedOk = Write-DbVerdict ('10 deneme; beklemeler 2/4/8/16/32/59/59/59/59 + 0-1 sn jitter (katlanarak artıyor, hiçbiri 60''ı geçmiyor); ' +
    'son deneme Failed; fatura ve outbox Başarısız (10 deneme); simülatörde 0 kayıt') `
    ("$($attempts.Count) deneme, $($bad.Count) uyumsuz bekleme, en uzun plan $maxWait sn; son deneme $($last.Outcome); " +
     "fatura $($row[0]), outbox $($row[1]) ($($row[2]) deneme); simülatörde $erpCount kayıt") `
    ($attempts.Count -eq 10 -and $bad.Count -eq 0 -and $maxWait -le 60 -and $last.Outcome -eq 'Failed' -and
     $row[0] -eq 'Başarısız' -and $row[1] -eq 'Başarısız' -and $row[2] -eq '10' -and $erpCount -eq 0)

# --- resend ----------------------------------------------------------------------------------------------------------
Restart-Simulator @{ Simulator__Rates__Success = 100; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0
                     Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0 }
Write-Step "POST $ServiceUrl/api/v1/invoices/$number/resend"
$r = Send-ServiceResend $number
Write-Host "  HTTP $($r.HttpStatus), status $($r.Status)"
Wait-QueueDrained $number $number 60 | Out-Null

Write-DbHeader 'Madde 4 - resend sonrası' "Fatura numarası: $number"
Show-ServiceQuery "SELECT invoice_number, status, erp_reference, send_attempt_count, last_error FROM invoices WHERE invoice_number = '$number';"
Show-ServiceQuery "SELECT invoice_number, status, attempt_count, processed_at, last_error FROM erp_outbox WHERE invoice_number = '$number';"
Show-ErpQuery "SELECT id, invoice_number, erp_reference, behavior, received_at FROM invoices WHERE invoice_number = '$number' ORDER BY id;"
$state = @(Get-ServiceRows "SELECT status, coalesce(erp_reference, '-') FROM invoices WHERE invoice_number = '$number';")[0] -split '\|'
$erpRefs = @(Get-ErpRows "SELECT erp_reference FROM invoices WHERE invoice_number = '$number' ORDER BY id;")
Write-Host ''
$resendOk = Write-DbVerdict 'resend 202 Bekliyor; fatura Gönderildi; simülatörde 1 kayıt, referansı faturadakiyle aynı' `
    "resend $($r.HttpStatus) $($r.Status); fatura $($state[0]); simülatörde $($erpRefs.Count) kayıt, referans $($state[1]) / $($erpRefs -join ',')" `
    ($r.HttpStatus -eq 202 -and $r.Status -eq 'Bekliyor' -and $state[0] -eq 'Gönderildi' -and $erpRefs.Count -eq 1 -and $erpRefs[0] -eq $state[1])

Restart-Simulator
Write-Result ($failedOk -and $resendOk) ("$($attempts.Count) deneme, en uzun bekleme $maxWait sn, 10. denemede $($row[0]); " +
    "resend sonrası $($state[0]) ($($state[1]))")
