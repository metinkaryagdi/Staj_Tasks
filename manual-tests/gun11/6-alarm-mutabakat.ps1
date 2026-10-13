# Alarm 4 (BasariliMutabakatYok): son 2 saatte başarıyla tamamlanmış bir mutabakat çalışması yok.
#   .\manual-tests\gun11\6-alarm-mutabakat.ps1
# Koşul: Fatura Servisi mutabakat aralığı 1 dakika olacak şekilde yeniden başlatılır ve bir çalışma tamamlanır. Sonra ERP
# Simülatörü durdurulur: her dakika başlayan çalışma ERP'nin kayıtlarını alamaz ve Başarısız olur. Son başarılı çalışmanın
# üzerinden 2 saat geçince alarm tetiklenir (yaklaşık 2 saat 5 dakika sürer). Çözülme: simülatör başlatılır, bir dakika
# içindeki çalışma Tamamlandı olur. Sonunda Fatura Servisi normal ayarlarla yeniden başlatılır.
. "$PSScriptRoot\_common.ps1"

Write-Title 'Alarm 4: son 2 saatte başarılı mutabakat yok'
Show-AlertRule 'BasariliMutabakatYok'
$since = Get-UtcStamp

Restart-InvoiceService @{ Reconciliation__IntervalMinutes = 1 }
Write-Step 'Bir mutabakat çalışması tamamlanıyor'
Show-Run (Invoke-Reconciliation).run.id
Write-Step 'ERP Simülatörü durduruluyor; bundan sonraki çalışmalar Başarısız olur'
Invoke-Compose @('stop', 'erp-simulator')
$stoppedAt = Get-UtcStamp

$passed = Test-AlertCycle 'BasariliMutabakatYok' $since -FireTimeoutSeconds 8400 -ResolveTimeoutSeconds 300 -Resolve {
    Write-Host '  Simülatör kapalıyken çalışmalar:' -ForegroundColor DarkGray
    Show-ServiceQuery "SELECT status, count(*), min(started_at) AS ilk, max(started_at) AS son FROM reconciliation_runs WHERE started_at >= '$stoppedAt+00' GROUP BY status;"
    Show-ServiceQuery "SELECT max(finished_at) AS son_tamamlanan FROM reconciliation_runs WHERE status = 'Tamamlandı';"
    Restart-Simulator
}
Show-ServiceQuery "SELECT id, status, started_at, finished_at, left(error, 80) AS hata FROM reconciliation_runs ORDER BY id DESC LIMIT 3;"
Restart-InvoiceService
Write-Result $passed 'Alarm tetiklendi ve çözüldü bildirimi geldi (alıcının logu)'
