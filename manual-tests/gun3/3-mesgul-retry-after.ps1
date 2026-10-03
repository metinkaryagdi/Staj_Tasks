# Gün 3 - Madde 3: Busy %100 iken 5 fatura gönder, bir dakika sonra simülatörü Success %100 ile yeniden başlat.
# Loglarla her denemeden önce beklenen sürenin Retry-After değerine eşit olduğu gösterilir; aynı test Retry-After
# tarih biçimiyle (HTTP-date) tekrarlanır. ~4 dk.
#
# Her 429'dan sonra servis logunda: retryAfter=<başlıktaki değer> wait=<planlanan bekleme>. Planlanan bekleme
# saniye biçiminde başlıktaki sayının kendisi, tarih biçiminde "tarih - cevabın geldiği an". Bir sonraki denemenin
# başlangıcına kadar gerçekten geçen süre de ölçülür (worker kuyruğa 250 ms'de bir baktığı için en fazla ~1 sn fazlası).
# Simülatör yeniden başlarken (birkaç sn) gelen bir deneme "ulaşılamadı" alır ve backoff ile bekler; o deneme 429 olmadığı
# için Retry-After karşılaştırmasına girmez.
. "$PSScriptRoot\_common.ps1"
# Script bir hatayla yarıda kesilirse simülatör değiştirilmiş ayarda (ör. ServerError %100 ya da durdurulmuş) kalıp sonraki
# testleri bozmasın: varsayılan ayarlarına döndürülür, hata yine yukarı iletilir.
trap { Write-Host "Hata: $_ - simülatör varsayılan ayarlarına döndürülüyor." -ForegroundColor Red; try { Restart-Simulator } catch { }; break }

Write-Title '3) Busy %100 -> 5 fatura, 1 dk sonra Success %100: her denemeden önce beklenen süre = Retry-After'

Wait-Service
$inv = [Globalization.CultureInfo]::InvariantCulture
$allPassed = $true
$summary = @()

foreach ($format in 'Seconds', 'HttpDate') {
    $title = if ($format -eq 'Seconds') { 'Retry-After saniye biçiminde' } else { 'Retry-After tarih biçiminde (HTTP-date)' }
    Restart-Simulator @{ Simulator__Rates__Success = 0; Simulator__Rates__Busy = 100; Simulator__Rates__ServerError = 0
                         Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0; Simulator__RetryAfterFormat = $format }
    Write-Step "$title`: 5 fatura oluşturuluyor, 60 sn bekleniyor"
    $range = New-ServiceInvoices 5
    Start-Sleep -Seconds 60
    Restart-Simulator @{ Simulator__Rates__Success = 100; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0
                         Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0 }
    Wait-QueueDrained $range.From $range.To 120 | Out-Null

    $numbers = @(Get-ServiceRows "SELECT invoice_number FROM invoices WHERE invoice_number BETWEEN '$($range.From)' AND '$($range.To)' ORDER BY 1;")

    Write-Step "Servis logu: 429 alan denemeler ($($numbers[0]) faturası)"
    Get-ServiceLog | Where-Object { $_ -match "ERP send invoice=$($numbers[0]) " } |
        ForEach-Object { Write-Host ('  ' + ($_ -replace ' info: InvoiceService\.Application\.Outbox\.OutboxProcessor\[0\]', '' -replace ' erpReference=.*$', '')) }

    $attempts = @(Get-SendAttempts $numbers)
    Show-SendAttempts $attempts

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
    Write-DbHeader "Madde 3 - $title" "Fatura aralığı: $($range.From) .. $($range.To)"
    Show-ServiceQuery "SELECT invoice_number, status, erp_reference, send_attempt_count FROM invoices WHERE $where ORDER BY 1;"
    Show-ErpQuery "SELECT invoice_number, count(*) AS kayit, string_agg(erp_reference, ',') AS referans FROM invoices WHERE $where GROUP BY 1 ORDER BY 1;"
    $sent = @(Get-ServiceRows "SELECT invoice_number || '=' || erp_reference FROM invoices WHERE $where AND status = 'Gönderildi' ORDER BY 1;")
    $erp = @(Get-ErpRows "SELECT invoice_number || '=' || erp_reference FROM invoices WHERE $where ORDER BY 1;")
    $same = @($sent | Where-Object { $erp -contains $_ }).Count
    Write-Host ''
    $ok = Write-DbVerdict ("429'dan sonraki her denemede plan = Retry-After ve gerçekten o kadar beklendi; 5 fatura Gönderildi, " +
        'simülatörde her birinden 1 kayıt (Busy kayıt açmaz), referanslar aynı') `
        "$checked bekleme ölçüldü, $($bad.Count) uyumsuz; $($sent.Count) Gönderildi, simülatörde $($erp.Count) kayıt, $same referans aynı" `
        ($checked -ge 5 -and $bad.Count -eq 0 -and $sent.Count -eq 5 -and $erp.Count -eq 5 -and $same -eq 5)
    $allPassed = $allPassed -and $ok
    $summary += "$title`: $checked bekleme, $($bad.Count) uyumsuz"
}

Restart-Simulator
Write-Result $allPassed ($summary -join '; ')
