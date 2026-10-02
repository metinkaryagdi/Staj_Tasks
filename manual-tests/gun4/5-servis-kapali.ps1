# Gün 4 - Kontrol listesi 5: Fatura Servisi 2 dakika durdurulur, bu sırada simülatör haber göndermeye devam eder.
# Servis açılınca simülatörün tekrar gönderdiği haberlerle bütün faturalar kesin duruma ulaşır. ~5 dk.
# 20 fatura Gönderildi olur olmaz servis durdurulur: haberlerinin hepsi (kayıttan 2-30 sn sonra) servis kapalıyken gönderilir.
# POST Success %100 ve haber sorunları 0: "bütün faturalar kesin durumda" ancak karar kaybolmazsa mümkün.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: $_ - servis başlatılıyor, simülatör varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Invoke-Compose @('start', 'invoice-service') } catch { }; try { Restart-Simulator } catch { }; break }

Write-Title 'Kontrol listesi 5) Fatura Servisi 2 dk kapalı, simülatör haber göndermeye devam ediyor'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
Restart-Simulator (Get-SimSettings)
$numbers = New-Invoices 20
$list = InList $numbers
Wait-InvoicesIn $numbers @('Gönderildi', 'İşleme Alındı', 'Onaylandı', 'Reddedildi') 60 'Gönderildi' | Out-Null
$before = Count-Service "SELECT count(*) FROM erp_webhook_events WHERE invoice_number IN ($list);"

# -t 0: hemen durdur (zarif kapanmayı beklerken ilk haberler hâlâ ulaşabiliyor).
Invoke-Compose @('stop', '-t', '0', 'invoice-service')
$stoppedAt = [datetime]::UtcNow
Write-Host "  Fatura Servisi durduruldu: $($stoppedAt.ToString('HH:mm:ss')) UTC (durdurma komutundan hemen önce serviste haber: $before)"
$watch = [Diagnostics.Stopwatch]::StartNew()
while ($watch.Elapsed.TotalSeconds -lt 120) {
    Start-Sleep -Seconds 20
    $tries = @(Get-ErpRows "SELECT count(*) FILTER (WHERE attempt_count > 0 AND status = 'Pending') || '|' || coalesce(sum(attempt_count), 0) FROM webhook_deliveries WHERE invoice_number IN ($list);")[0] -split '\|'
    Write-Host ('  {0,4:N0} sn: simülatör {1} gönderim denedi, {2} haber tekrar denenmeyi bekliyor' -f $watch.Elapsed.TotalSeconds, $tries[1], $tries[0]) -ForegroundColor DarkGray
}
$startCommandAt = [datetime]::UtcNow
Invoke-Compose @('start', 'invoice-service')
Wait-Service
$startedAt = [datetime]::UtcNow
Write-Host "  Fatura Servisi açıldı: $($startedAt.ToString('HH:mm:ss')) UTC ($([math]::Round(($startedAt - $stoppedAt).TotalSeconds)) sn kapalı kaldı)"

$seconds = Wait-InvoicesIn $numbers @('Onaylandı', 'Reddedildi') 240 'kesin durumda'
Write-Host "  20 fatura servis açıldıktan $seconds sn sonra kesin durumda"
Wait-EventsDone $numbers | Out-Null

Write-DbHeader 'ERP Simülatörü' 'Servis kapalıyken başarısız olan ve servis açılınca teslim edilen gönderimler'
Show-ErpQuery ("SELECT event_type, status, attempt_count AS deneme, count(*) AS haber, to_char(min(completed_at), 'HH24:MI:SS') AS ilk_teslim, " +
    "to_char(max(completed_at), 'HH24:MI:SS') AS son_teslim FROM webhook_deliveries WHERE invoice_number IN ($list) GROUP BY 1, 2, 3 ORDER BY 1, 3;")
$retried = Count-Erp "SELECT count(*) FROM webhook_deliveries WHERE invoice_number IN ($list) AND attempt_count > 1 AND status = 'Delivered';"
# Servis durdurulmadan önce teslim edilenler simülatörün tablosundan sayılır: durdurma komutu bir saniye kadar sürer ve
# o arada ilk haberler normal yoldan ulaşabilir (durdurmadan önceki anlık sayım bunları kaçırıyordu).
$before = Count-Erp "SELECT count(*) FROM webhook_deliveries WHERE invoice_number IN ($list) AND completed_at < '$($stoppedAt.ToString('yyyy-MM-dd HH:mm:ss.fff'))+00';"
$during = Count-Erp ("SELECT count(*) FROM webhook_deliveries WHERE invoice_number IN ($list) AND completed_at >= '$($stoppedAt.ToString('yyyy-MM-dd HH:mm:ss.fff'))+00' " +
    "AND completed_at < '$($startCommandAt.ToString('yyyy-MM-dd HH:mm:ss.fff'))+00';")
$failedWhileDown = Count-Erp "SELECT count(*) FROM webhook_deliveries WHERE invoice_number IN ($list) AND attempt_count > 1;"
$notDelivered = Count-Erp "SELECT count(*) FROM webhook_deliveries WHERE invoice_number IN ($list) AND status <> 'Delivered';"

Write-Host ''
Write-Host '  Simülatör logundan bir örnek (bir haberin bütün denemeleri):' -ForegroundColor Cyan
$sample = @(Get-ErpRows "SELECT event_id FROM webhook_deliveries WHERE invoice_number IN ($list) ORDER BY attempt_count DESC, id LIMIT 1;")[0]
Get-SimulatorLog | Where-Object { $_ -match "event=$sample " } | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

Write-DbHeader 'Fatura Servisi'
Show-ServiceQuery "SELECT status, count(*) FROM invoices WHERE invoice_number IN ($list) GROUP BY status;"
$final = Count-Service "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status IN ('Onaylandı', 'Reddedildi');"
$events = Count-Service "SELECT count(*) FROM erp_webhook_events WHERE invoice_number IN ($list);"

Check (Write-DbVerdict 'servis kapalıyken hiçbir haber teslim edilmedi' "kapalıyken teslim $during" ($during -eq 0))
Check (Write-DbVerdict 'kapanmadan önce gelenler dışındaki bütün haberler servis açılınca tekrar denemeyle teslim edildi' `
    "kapanmadan önce $before + tekrar denemeyle $retried = $($before + $retried) / 40; teslim edilmeyen $notDelivered" `
    ($before + $retried -eq 40 -and $retried -ge 1 -and $notDelivered -eq 0))
Check (Write-DbVerdict 'serviste 40 haber; 20 fatura Onaylandı ya da Reddedildi' "$events haber, $final fatura" ($events -eq 40 -and $final -eq 20))

Restart-Simulator
Write-Result $allPassed 'servis 2 dk kapalıyken gönderilen haberler tekrar gönderimle ulaştı, bütün faturalar kesin durumda'
