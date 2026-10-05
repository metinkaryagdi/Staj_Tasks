# Gün 5 - Kontrol listesi 7: servisin tanımadığı bir fatura numarasıyla geçerli imzalı bir haber gönder; eşiği ayardan
# kısaltarak (1 dk) bekle: zamanlanmış mutabakat haberi Yok Sayıldı yapar. ~2-3 dk.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: $_ - servis varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Restart-InvoiceService } catch { }; break }

Write-Title 'Kontrol listesi 7) Tanınmayan faturanın haberi: eşik 1 dk, zamanlanmış mutabakat Yok Sayıldı yapıyor'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
Restart-InvoiceService @{ Reconciliation__IntervalMinutes = 1; Reconciliation__UnknownEventAfterMinutes = 1 }

$number = "YOK-$(Get-Date -Format 'yyyyMMddHHmmss')"
$eventId = "evt-yok-$(Get-Date -Format 'yyyyMMddHHmmss')"
Write-Step "Servisin tanımadığı $number için geçerli imzalı invoice.received haberi gönderiliyor"
$secret = Get-WebhookSecret
$body = [Text.Encoding]::UTF8.GetBytes((New-WebhookBody $eventId 'invoice.received' $number 'ERP-YOK-1' ''))
$timestamp = "$(Get-UnixNow)"
$sent = Send-Webhook $body $timestamp (Get-WebhookSignature $secret $timestamp $body)
Write-Host "  HTTP $($sent.Status)"
Write-DbHeader 'Fatura Servisi' 'Haber ilk geldiğinde'
Show-ServiceQuery "SELECT event_id, event_type, invoice_number, status, ignore_reason, received_at FROM erp_webhook_events WHERE event_id = '$eventId';"
$first = (@(Get-ServiceRows "SELECT status FROM erp_webhook_events WHERE event_id = '$eventId';") -join '')

Write-Step 'Zamanlanmış mutabakatın haberi Yok Sayıldı yapması bekleniyor (en çok 4 dk)'
$watch = [Diagnostics.Stopwatch]::StartNew()
$status = $first
while ($status -ne 'Yok Sayıldı' -and $watch.Elapsed.TotalSeconds -lt 240) {
    Start-Sleep -Seconds 5
    $status = (@(Get-ServiceRows "SELECT status FROM erp_webhook_events WHERE event_id = '$eventId';") -join '')
}
Write-Host ('  {0:N0} sn sonra durum: {1}' -f $watch.Elapsed.TotalSeconds, $status)

Write-DbHeader 'Fatura Servisi' 'Haber ve bulgu'
Show-ServiceQuery "SELECT event_id, status, ignore_reason, processed_at FROM erp_webhook_events WHERE event_id = '$eventId';"
Show-ServiceQuery ("SELECT f.run_id, r.status AS calisma, f.finding_type, f.action, f.details FROM reconciliation_findings f " +
                   "JOIN reconciliation_runs r ON r.id = f.run_id WHERE f.invoice_number = '$number';")
$evt = @(Get-ServiceRows "SELECT status, ignore_reason, coalesce(processed_at::text, '') FROM erp_webhook_events WHERE event_id = '$eventId';")[0] -split '\|'
$finding = @(Get-ServiceRows "SELECT finding_type, action FROM reconciliation_findings WHERE invoice_number = '$number';")

Check (Write-DbVerdict 'haber ilk geldiğinde 200 ve Bekliyor' "HTTP $($sent.Status), $first" ($sent.Status -eq 200 -and $first -eq 'Bekliyor'))
Check (Write-DbVerdict 'sonra Yok Sayıldı, neden Fatura Yok, processed_at boş' ($evt -join ' / ') `
    ($evt[0] -eq 'Yok Sayıldı' -and $evt[1] -eq 'Fatura Yok' -and $evt[2] -eq ''))
Check (Write-DbVerdict 'bulgu: Tanınmayan Haber / Düzeltildi' ($finding -join ', ') ($finding.Count -eq 1 -and $finding[0] -eq 'Tanınmayan Haber|Düzeltildi'))
Check (Write-DbVerdict 'serviste bu numarayla fatura oluşmadı' (Count-Service "SELECT count(*) FROM invoices WHERE invoice_number = '$number';") `
    ((Count-Service "SELECT count(*) FROM invoices WHERE invoice_number = '$number';") -eq 0))

Restart-InvoiceService
Write-Result $allPassed 'tanınmayan faturanın bekleyen haberi eşik dolunca Yok Sayıldı (Fatura Yok) oldu'
