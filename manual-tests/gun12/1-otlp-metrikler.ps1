# Adım 1: metrikler beta Prometheus paketi yerine OTLP ile OpenTelemetry Collector'a gidiyor, Prometheus Collector'dan
# topluyor. Kontrol edilenler: projelerde beta paket yok, servislerin /metrics adresi kalktı, Prometheus'un tek hedefi
# Collector ve ayakta, metrik adları Gün 11'deki /metrics çıktısıyla aynı, panonun bütün sorguları ve beş alarm kuralı
# çalışıyor. Histogramlar ilk ölçümden önce görünmez: önce bir fatura gönderilir ve bir mutabakat çalıştırılır.
#   .\manual-tests\gun12\1-otlp-metrikler.ps1
. "$PSScriptRoot\_common.ps1"

Write-Title 'Adım 1: metrikler OTLP ile Collector üzerinden'
$out = Join-Path $OutputDir 'gun12-1-otlp-metrikler.txt'
$report = [Collections.Generic.List[string]]::new()
function Write-Line([string]$Text) { Write-Host $Text; $report.Add($Text) }

Write-Step 'Projelerdeki OpenTelemetry paketleri (beta sürüm olmamalı)'
$packages = @(Get-ChildItem $RepoRoot -Recurse -Filter *.csproj | Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' } |
    Select-String -Pattern 'Include="(OpenTelemetry[^"]*)" Version="([^"]+)"' |
    ForEach-Object { [pscustomobject]@{ Proje = $_.Filename; Paket = $_.Matches[0].Groups[1].Value; Sürüm = $_.Matches[0].Groups[2].Value } })
$packages | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Line $_.TrimEnd() }
$beta = @($packages | Where-Object { $_.Sürüm -match '-' })
Write-Result ($beta.Count -eq 0) "Beta paket sayısı: $($beta.Count)"
$report.Add("Beta paket sayısı: $($beta.Count)")

Write-Step 'Servislerin /metrics adresi (artık yok, 404 beklenir)'
$metricsGone = $true
foreach ($url in "$ServiceUrl/metrics", "$SimulatorUrl/metrics") {
    try { $code = (Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 10).StatusCode }
    catch { $code = [int]$_.Exception.Response.StatusCode }
    Write-Line "  $url -> HTTP $code"
    if ($code -ne 404) { $metricsGone = $false }
}
Write-Result $metricsGone '/metrics adresleri kaldırıldı'

Write-Step 'Bir fatura gönderiliyor ve bir mutabakat çalıştırılıyor (histogramların ilk ölçümü)'
$number = (New-ServiceInvoice).InvoiceNumber
Wait-InvoicesIn @($number) @('Gönderildi', 'İşleme Alındı', 'Onaylandı', 'Reddedildi', 'Başarısız') 300 'gönderildi' | Out-Null
Show-Run (Invoke-Reconciliation).run.id
# Son mutabakatın zamanı veritabanından 15 sn'de bir okunur; uygulamalar 5 sn'de bir gönderir, Prometheus 5 sn'de bir
# toplar.
Start-Sleep -Seconds 25

Write-Step "Prometheus'un hedefleri"
$targets = @((Invoke-RestMethod "$PrometheusUrl/api/v1/targets" -TimeoutSec 10).data.activeTargets)
$targets | ForEach-Object { Write-Line "  job=$($_.labels.job) adres=$($_.scrapeUrl) durum=$($_.health)" }
Write-Result ($targets.Count -eq 1 -and $targets[0].labels.job -eq 'otel-collector' -and $targets[0].health -eq 'up') "Tek hedef Collector ve ayakta"

Write-Step "Prometheus'taki metrik adları, Gün 11'deki /metrics çıktısıyla karşılaştırma"
# Gün 11'de iki uygulamanın /metrics adresinde görünen adlar (bir gönderim ve bir mutabakattan sonra).
$expected = @{
    'invoice-service' = @('erp_send_attempts_total', 'erp_send_duration_seconds_bucket', 'erp_send_duration_seconds_count',
        'erp_send_duration_seconds_sum', 'erp_send_pace_wait_seconds_bucket', 'erp_send_pace_wait_seconds_count',
        'erp_send_pace_wait_seconds_sum', 'erp_webhooks_received_total', 'invoices_by_status', 'invoices_created_total',
        'invoices_stuck', 'outbox_oldest_wait_seconds', 'outbox_queued', 'reconciliation_duration_seconds_bucket',
        'reconciliation_duration_seconds_count', 'reconciliation_duration_seconds_sum', 'reconciliation_findings_total',
        'reconciliation_last_completed_time_seconds', 'reconciliation_runs_total', 'target_info')
    'erp-simulator' = @('erp_simulator_invoice_requests_total', 'erp_simulator_rate_limited_total', 'target_info')
}
$namesMatch = $true
foreach ($job in 'invoice-service', 'erp-simulator') {
    $actual = @(Get-Prometheus "count by (__name__) ({job=`"$job`"})" | ForEach-Object { $_.metric.__name__ } | Sort-Object)
    $diff = @(Compare-Object ($expected[$job] | Sort-Object) $actual)
    Write-Line "  job=$job : $($actual.Count) ad, beklenen $($expected[$job].Count), fark $($diff.Count)"
    $diff | ForEach-Object { Write-Line ("    {0} {1}" -f $(if ($_.SideIndicator -eq '<=') { 'eksik:' } else { 'fazla:' }), $_.InputObject) }
    if ($diff.Count -ne 0) { $namesMatch = $false }
}
Write-Result $namesMatch 'Metrik adları aynı'

Write-Step "Panonun sorguları (monitoring/grafana/dashboards/fatura-servisi.json), Prometheus'ta"
$dashboard = Get-Content (Join-Path $RepoRoot 'monitoring\grafana\dashboards\fatura-servisi.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$panelsOk = $true
foreach ($panel in $dashboard.panels) {
    foreach ($target in @($panel.targets)) {
        if (-not $target.expr) { continue }
        $rows = @(Get-Prometheus $target.expr)
        # "> 0" süzgeçli bulgu sorgusu bulgu yoksa boş döner; sorgunun hatasız çalışması yeterli.
        $optional = $target.expr -match '> 0$'
        $ok = $rows.Count -gt 0 -or $optional
        if (-not $ok) { $panelsOk = $false }
        Write-Line ("  [{0}] {1}: {2} seri{3}" -f $(if ($ok) { 'OK' } else { 'BOŞ' }), $panel.title, $rows.Count, $(if ($optional -and $rows.Count -eq 0) { ' (bulgu yok, boş olabilir)' } else { '' }))
    }
}
Write-Result $panelsOk 'Panonun bütün sorguları değer döndürüyor'

Write-Step 'Alarm kuralları'
$rules = @((Invoke-RestMethod "$PrometheusUrl/api/v1/rules" -TimeoutSec 10).data.groups.rules)
$rules | ForEach-Object { Write-Line "  $($_.name): $($_.state), sağlık=$($_.health)" }
Write-Result (@($rules | Where-Object { $_.health -ne 'ok' }).Count -eq 0) "$($rules.Count) kural yüklü, hepsi hatasız değerlendiriliyor"

$report | Set-Content $out -Encoding UTF8
Write-Host "  Çıktı: manual-tests\output\gun12-1-otlp-metrikler.txt" -ForegroundColor DarkGray
