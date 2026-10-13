# 4. madde: yük yokken ve hata oranları sıfırken 15 dakika boyunca hiçbir alarm tetiklenmiyor.
#   .\manual-tests\gun11\8-alarmsiz-15dk.ps1
# Simülatör hatasız başlatılır: bütün istekler Success, haber sorunlarının oranları 0. Fatura gönderilmez. Önceki testlerden
# kalan alarmların çözülmesi beklenir (en fazla 10 dakika), sonra 15 dakika boyunca 15 saniyede bir Prometheus'taki alarmlara
# ve alıcının loguna bakılır. Bekleme öncesinde bir mutabakat çalışması tamamlanır: sistemin son 2 saatte başarılı bir
# çalışması olsun (servis 60 dakikada bir çalıştırır; yeniden başlatılmış bir servisin ilk çalışması bir saat sonradır).
param([int]$Minutes = 15)

. "$PSScriptRoot\_common.ps1"

Write-Title "Yük yokken ve hata oranları sıfırken $Minutes dakika alarm yok"

Restart-Simulator @{
    Simulator__Rates__Success = 100; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0
    Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0
    Webhooks__Problems__DuplicateRate = 0; Webhooks__Problems__OrderMixRate = 0; Webhooks__Problems__LostDecisionRate = 0
    Webhooks__Problems__FakeRate = 0; Webhooks__Problems__ReplayRate = 0
}
Write-Step 'Bir mutabakat çalışması tamamlanıyor'
Show-Run (Invoke-Reconciliation).run.id

Write-Step 'Önceki testlerden kalan alarmların çözülmesi bekleniyor'
$waitSince = Get-UtcStamp
$deadline = (Get-Date).AddMinutes(10)
$wereOpen = @{}
while (@(Get-ActiveAlerts).Count -gt 0) {
    if ((Get-Date) -gt $deadline) { Get-ActiveAlerts | Format-Table -AutoSize | Out-String | Write-Host; throw 'Alarmlar 10 dakikada çözülmedi.' }
    foreach ($a in Get-ActiveAlerts) { if ($a.Durum -eq 'firing') { $wereOpen[$a.Alarm] = $true } }
    Write-Host "  $(Get-Date -Format 'HH:mm:ss') açık: $((Get-ActiveAlerts | ForEach-Object { "$($_.Alarm) ($($_.Durum))" }) -join ', ')" -ForegroundColor DarkGray
    Start-Sleep -Seconds 15
}
# Alertmanager sends the resolved notification some seconds after Prometheus clears the alert; it must reach the receiver
# before watching starts, or it is counted in the window.
foreach ($name in $wereOpen.Keys) {
    if (-not (Wait-ReceiverLine $name 'resolved' $waitSince 120)) { throw "$name için çözüldü bildirimi 2 dakikada gelmedi." }
    Write-Host "  $name çözüldü bildirimi alıcıda." -ForegroundColor DarkGray
}
Write-Step 'Kuyruk ve takılı fatura (Prometheus)'
Write-Host ("  kuyrukta {0}, en eski bekleme {1} sn, takılı {2}" -f (Get-PrometheusValue 'max(outbox_queued)'),
    (Get-PrometheusValue 'max(outbox_oldest_wait_seconds)'), (Get-PrometheusValue 'max(invoices_stuck)'))

$since = Get-UtcStamp
$end = (Get-Date).AddMinutes($Minutes)
Write-Step "$Minutes dakika izleniyor ($since UTC'den $($end.ToUniversalTime().ToString('HH:mm:ss')) UTC'ye)"
$checks = 0; $seen = @{}
while ((Get-Date) -lt $end) {
    $checks++
    foreach ($a in Get-ActiveAlerts) { $seen["$($a.Alarm) ($($a.Durum))"] = $true }
    if ($checks % 20 -eq 0) { Write-Host "  $(Get-Date -Format 'HH:mm:ss') $checks kontrol, görülen alarm: $($seen.Count)" -ForegroundColor DarkGray }
    Start-Sleep -Seconds 15
}
$lines = @(Get-ReceiverLines $since)
Write-Host "  $checks kontrol; Prometheus'ta görülen alarm: $(if ($seen.Count) { $seen.Keys -join ', ' } else { 'yok' }); alıcıda satır: $($lines.Count)"
$lines | ForEach-Object { Write-Host "    $_" }
Write-Result ($seen.Count -eq 0 -and $lines.Count -eq 0) "$Minutes dakika boyunca ne Prometheus'ta (pending ya da firing) ne alıcıda alarm var"
