# Gün 7 - Ek: zamanlayıcının başlattığı çalışmada "Başlatan" = Zamanlayıcı ve operator_actions'a kayıt yazılmıyor. ~2 dk.
#
#   Servis 1 dakikalık mutabakat aralığıyla yeniden başlatılır; ilk zamanlanmış çalışma beklenir. Sonda servis ayar
#   dosyasındaki değerlerle (60 dk) yeniden başlatılır.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: $_ - servis varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Restart-InvoiceService } catch { }; break }

Write-Title 'Ek) Zamanlanmış çalışmanın başlatanı'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
$lastRun = [long]@(Get-ServiceRows 'SELECT coalesce(max(id), 0) FROM reconciliation_runs;')[0]
$lastAction = Get-LastActionId
Restart-InvoiceService @{ Reconciliation__IntervalMinutes = 1 }

Write-Step 'İlk zamanlanmış çalışma bekleniyor (en çok 3 dk)'
$watch = [Diagnostics.Stopwatch]::StartNew()
while ((Count-Service "SELECT count(*) FROM reconciliation_runs WHERE id > $lastRun AND status <> 'Çalışıyor';") -eq 0) {
    if ($watch.Elapsed.TotalMinutes -gt 3) { throw '3 dk içinde zamanlanmış çalışma olmadı.' }
    Start-Sleep -Seconds 5
}
Restart-InvoiceService

Write-DbHeader 'Fatura Servisi' 'Zamanlanmış çalışma'
Show-ServiceQuery "SELECT id, status, started_by, started_at FROM reconciliation_runs WHERE id > $lastRun ORDER BY id;"
$startedBy = @(Get-ServiceRows "SELECT started_by FROM reconciliation_runs WHERE id > $lastRun ORDER BY id LIMIT 1;")[0]
Check (Write-DbVerdict "started_by = Zamanlayıcı" "$startedBy" ($startedBy -eq 'Zamanlayıcı'))
$actions = Count-Service "SELECT count(*) FROM operator_actions WHERE id > $lastAction AND action = 'Mutabakat Başlatma';"
Check (Write-DbVerdict 'operator_actions''a mutabakat kaydı yazılmadı' "$actions satır" ($actions -eq 0))

Write-Result $allPassed 'Ek: zamanlayıcı'
