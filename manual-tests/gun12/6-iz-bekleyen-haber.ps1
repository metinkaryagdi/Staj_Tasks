# Kontrol listesi 5: fatura Gönderildi olmadan gelen bir haberin izinde, haberin beklediği ve fatura Gönderildi olunca
# işlendiği görünüyor.
#   .\manual-tests\gun12\6-iz-bekleyen-haber.ps1
# Simülatör faturayı kaydeder ama 500 döner (SaveThenError %100) ve ilk haberi kayıttan 0-1 sn sonra gönderir: servis
# faturayı henüz Gönderildi yapmamışken (sonraki deneme 2 sn'den sonra) haber gelir ve Bekliyor kalır. Sonraki deneme
# ERP'ye sorar, faturayı bulur, Gönderildi yapar ve bekleyen haberi aynı anda uygular.
. "$PSScriptRoot\_common.ps1"

Write-Title 'Kontrol listesi 5: fatura Gönderildi olmadan gelen haber'
$settings = Get-SimSettings 'SaveThenError'
$settings['Webhooks__FirstEventMinSeconds'] = 0
$settings['Webhooks__FirstEventMaxSeconds'] = 1
Restart-Simulator $settings

Write-Step 'Fatura oluşturuluyor'
$number = (New-ServiceInvoice).InvoiceNumber
Write-Host "  $number"
Wait-InvoicesIn @($number) @('Onaylandı', 'Reddedildi') 120 'karar aldı' | Out-Null
Wait-EventsDone @($number) 60 | Out-Null

Write-Step 'Haberler (Fatura Servisi veritabanı)'
Show-ServiceQuery "SELECT event_id, event_type, status, received_at, processed_at FROM erp_webhook_events WHERE invoice_number = '$number' ORDER BY received_at;"
Show-ServiceQuery "SELECT status, send_attempt_count, updated_at FROM invoices WHERE invoice_number = '$number';"

Write-Step "Jaeger'daki iz"
$trace = Get-InvoiceTrace $number
Show-Trace $trace 'gun12-6-iz-bekleyen-haber.txt'

# Bekleyen haber: servise geldiğinde Bekliyor kalan; aynı event_id daha sonra bir denemede uygulanmış olmalı.
$waited = @($trace.Spans | Where-Object { $_.Name -eq 'POST /api/v1/erp-webhooks' -and $_.Tags['erp_event.status'] -eq 'Bekliyor' } | Sort-Object Start)
$found = $false
foreach ($w in $waited) {
    $id = $w.Tags['erp_event.id']
    $applied = @($trace.Spans | Where-Object { $_.Name -eq 'outbox.attempt' -and $_.Start -gt $w.Start -and
        @($_.Events | Where-Object { $_.event -eq 'erp event applied-after-send' -and $_.'erp_event.id' -eq $id -and $_.'erp_event.status' -eq 'İşlendi' }).Count -gt 0 })
    if ($applied.Count -eq 1) {
        Write-Host ("  Haber {0}: {1} ms'de geldi, Bekliyor kaldı; {2}. deneme ({3} ms, sonuç {4}) faturayı Gönderildi yapınca işlendi." -f `
            $id, $w.Start, $applied[0].Tags['outbox.attempt'], $applied[0].Start, $applied[0].Tags['outbox.outcome'])
        $found = $true
    }
}
Write-Result $found "Bekleyen haber izde: geldiğinde Bekliyor, fatura Gönderildi olunca aynı denemede İşlendi ($number)"
Write-Host "  Ekran görüntüsü: $JaegerUrl/trace/$($trace.TraceId)" -ForegroundColor DarkGray
Restart-Simulator
