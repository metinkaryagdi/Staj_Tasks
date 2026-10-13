# 1. madde: compose ayağa kalktıktan sonra Grafana panosu elle hiçbir şey yapmadan açılıyor.
#   docker compose up -d --build
#   .\manual-tests\gun11\1-pano-hazir.ps1
# Giriş yapılmadan (anonim) Grafana'nın panoyu ve Prometheus veri kaynağını verdiği, Prometheus'un üç hedeften de
# topladığı kontrol edilir. Ekran görüntüsü için pano tarayıcıda açılır: http://localhost:3000
. "$PSScriptRoot\_common.ps1"

Write-Title 'Grafana panosu elle bir şey yapmadan hazır'

Write-Step 'Grafana açılıyor'
$ready = $false
for ($i = 0; $i -lt 60 -and -not $ready; $i++) {
    try { $ready = (Invoke-RestMethod "$GrafanaUrl/api/health" -TimeoutSec 5).database -eq 'ok' } catch { Start-Sleep -Seconds 2 }
}
if (-not $ready) { throw 'Grafana 2 dakikada açılmadı: docker compose logs grafana' }

Write-Step 'Giriş yapmadan pano ve veri kaynağı'
# Read as UTF-8: Invoke-RestMethod in Windows PowerShell decodes Grafana's JSON as Latin-1.
$dashboard = $script:Http.GetStringAsync("$GrafanaUrl/api/dashboards/uid/fatura-servisi").GetAwaiter().GetResult() | ConvertFrom-Json
$panels = @($dashboard.dashboard.panels | Where-Object { $_.type -ne 'row' })
Write-Host "  Pano: $($dashboard.dashboard.title), $($panels.Count) panel; dosyadan yüklendi: $($dashboard.meta.provisioned) ($($dashboard.meta.provisionedExternalId)), arayüzden kaydedilebilir: $($dashboard.meta.canSave)"
$panels | ForEach-Object { Write-Host "    - $($_.title)" -ForegroundColor DarkGray }
$homeDashboard = Invoke-RestMethod "$GrafanaUrl/api/dashboards/home" -TimeoutSec 10
Write-Host "  Ana sayfa: $($homeDashboard.dashboard.title)"
$datasource = Invoke-RestMethod "$GrafanaUrl/api/datasources/uid/prometheus/health" -TimeoutSec 10
Write-Host "  Veri kaynağı: Prometheus, $($datasource.status) ($($datasource.message))"

Write-Step 'Prometheus hedefleri'
$targets = @((Invoke-RestMethod "$PrometheusUrl/api/v1/targets" -TimeoutSec 10).data.activeTargets)
$targets | ForEach-Object { [pscustomobject]@{ Job = $_.labels.job; Hedef = $_.labels.instance; Durum = $_.health; Hata = $_.lastError } } |
    Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$up = @($targets | Where-Object { $_.health -eq 'up' }).Count
$needed = @($targets | Where-Object { $_.labels.instance -ne 'invoice-service-2:8080' })
$neededUp = @($needed | Where-Object { $_.health -eq 'up' }).Count

$passed = $homeDashboard.dashboard.uid -eq 'fatura-servisi' -and $datasource.status -eq 'OK' -and $neededUp -eq $needed.Count
Write-Result $passed "Pano anonim açılıyor, ana sayfa, veri kaynağı çalışıyor, $neededUp / $($needed.Count) hedef up (invoice-service-2 yalnızca iki kopya testinde açık)"
Start-Process "$GrafanaUrl/d/fatura-servisi"
