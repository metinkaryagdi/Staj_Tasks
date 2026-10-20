# İki kısa doğrulama, açık yığın üzerinde; hiçbir container'ı yeniden oluşturmaz.
#   .\manual-tests\gun16\7-iz-collector-ve-iki-kopya.ps1 -Name uzun
# -Name: yığının açık olduğu volume'lerin adı (gun16-<Name>); compose başka volume'lerle açılmasın diye.
#
#   C) İz Collector'ı -CollectorMinutes dakika durdurulur: metriklerin Prometheus'ta kesintisiz sürmesi, MetrikToplanamiyor'un ve
#      CollectorIzReddediyor'un tetiklenmemesi beklenir. Sonra başlatılır ve kısa bir yükle (saniyede 5 fatura, 10 sn) izlerin
#      yeniden alındığı Collector'ın kendi sayacından okunur.
#   D) İkinci servis kopyası (invoice-service-2, iki-kopya profili) güncel kodla derlenip açılır: iki kopyanın metriklerinin metrik Collector'ından
#      ayrı ayrı (instance) geldiği görülür; sonra kopya durdurulur.
param([string]$Name = 'uzun', [int]$CollectorMinutes = 2)

. "$PSScriptRoot\_common.ps1"
Use-Gun10Volumes "gun16-$Name"

$out = Join-Path $OutputDir 'gun16-7-iz-collector-ve-iki-kopya.txt'
$report = [Collections.Generic.List[string]]::new()
function Write-Line([string]$Text) { Write-Host $Text; $report.Add($Text) }
function Format-Local([DateTimeOffset]$At) { $At.ToLocalTime().ToString('HH:mm:ss') }
function Get-AlertList { $a = @(Get-ActiveAlerts | ForEach-Object { "$($_.Alarm) $($_.Durum)" }); if ($a.Count) { $a -join ', ' } else { 'yok' } }
function Format-Value($V) { if ($null -eq $V) { 'yok' } else { $V } }

Write-Title 'İz Collector''ının durması ve iki servis kopyası'
Write-Line "Başlangıç ($(Format-Local ([DateTimeOffset]::UtcNow))): Prometheus'taki alarmlar: $(Get-AlertList)."

try {
    # C) İz Collector'ı
    Write-Step "C) İz Collector'ı $CollectorMinutes dakika durduruluyor"
    $sinceC = Get-UtcStamp; $fromC = [DateTimeOffset]::UtcNow
    Invoke-Compose @('stop', 'otel-collector')
    while (([DateTimeOffset]::UtcNow - $fromC).TotalMinutes -lt $CollectorMinutes) {
        Start-Sleep -Seconds 30
        Write-Host ("  {0}: up(otel-collector) {1}, invoice-service target_info {2}, erp-simulator target_info {3}; alarmlar: {4}" -f
            (Format-Local ([DateTimeOffset]::UtcNow)), (Format-Value (Get-PrometheusValue 'up{job="otel-collector"}')),
            (Format-Value (Get-PrometheusValue 'count(target_info{job="invoice-service"})')),
            (Format-Value (Get-PrometheusValue 'count(target_info{job="erp-simulator"})')), (Get-AlertList)) -ForegroundColor DarkGray
    }
    $toC = [DateTimeOffset]::UtcNow
    Write-Line ''
    Write-Line "C) İz Collector'ı $(Format-Local $fromC)-$(Format-Local $toC) arasında durduruldu."
    $down = @(Get-PrometheusRange 'up{job="otel-collector"} == 0' $fromC $toC 15 | ForEach-Object { $_.values }).Count
    Write-Line "  Prometheus'un iz Collector'ını toplayamadığı 15 sn'lik adım: $down"
    foreach ($job in 'invoice-service', 'erp-simulator') {
        $c = Test-MetricContinuity $job $fromC $toC
        Write-Line ("  {0} metrikleri: {1} adımın (5 sn) {2}'inde örnek yok" -f $job, $c.Steps, $c.Missing.Count)
    }
    foreach ($alert in 'MetrikToplanamiyor', 'CollectorIzReddediyor') {
        $states = @(Get-AlertStates $alert $fromC $toC)
        Write-Line ("  {0}: {1}" -f $alert, $(if ($states.Count) { ($states | ForEach-Object { "$($_.State) $(Format-Local $_.First)-$(Format-Local $_.Last)" }) -join '; ' } else { 'hiç pending ya da firing olmadı' }))
    }
    $lines = @(Get-ReceiverLines $sinceC)
    Write-Line "  Alıcıya bu sürede gelen alarm satırı: $($lines.Count)"
    foreach ($l in $lines) { Write-Line ("    " + ($l -replace ' summary=.*$', '')) }

    Write-Step "İz Collector'ı başlatılıyor, kısa yükle izlerin yeniden geldiğine bakılıyor"
    Invoke-Compose @('start', 'otel-collector')
    Start-Sleep -Seconds 20
    $before = Get-PrometheusValue 'sum(otelcol_receiver_accepted_spans_total{job="otel-collector"})'
    $runId = 'GUN16-7-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $null = Invoke-LoadTest @{ BASE_URLS = 'http://invoice-service:8080'; RATE = 5; DURATION = '10s'; RUN_ID = $runId }
    Start-Sleep -Seconds 30
    $after = Get-PrometheusValue 'sum(otelcol_receiver_accepted_spans_total{job="otel-collector"})'
    Write-Line ("  Başlatıldıktan sonra iz Collector'ının kabul ettiği span: yükten önce {0}, 50 faturalık yükten 30 sn sonra {1}." -f (Format-Value $before), (Format-Value $after))

    # D) İkinci servis kopyası
    Write-Step 'D) İkinci servis kopyası açılıyor'
    $fromD = [DateTimeOffset]::UtcNow
    # --build: ikinci kopyanın imajı ayrıca derlenir (docker compose up --build profildeki servisi derlemez).
    Invoke-Compose @('--profile', 'iki-kopya', 'up', '-d', '--build', 'invoice-service-2')
    Wait-Health 'http://localhost:5091'
    Start-Sleep -Seconds 30
    $instances = @(Get-Prometheus 'count by (instance) (target_info{job="invoice-service"})')
    Write-Line ''
    Write-Line "D) invoice-service-2 $(Format-Local $fromD)'te açıldı; 30 sn sonra Prometheus'ta invoice-service'in kopyaları (instance): $($instances.Count)."
    $series = @(Get-Prometheus 'count by (instance) (outbox_queued{job="invoice-service"})')
    Write-Line "  Kuyruk metriği (outbox_queued) gelen kopya: $($series.Count); alarmlar: $(Get-AlertList)."
}
finally {
    Write-Step "İz Collector'ı açık, ikinci kopya kapalı bırakılıyor"
    Invoke-Compose @('start', 'otel-collector')
    Invoke-Compose @('--profile', 'iki-kopya', 'stop', 'invoice-service-2')
    Start-Sleep -Seconds 30
    Write-Line ''
    Write-Line ("Bitiş ({0}): invoice-service kopyaları {1}; Prometheus'taki alarmlar: {2}." -f (Format-Local ([DateTimeOffset]::UtcNow)),
        @(Get-Prometheus 'count by (instance) (target_info{job="invoice-service"})').Count, (Get-AlertList))
    $report | Set-Content $out -Encoding UTF8
    Write-Host "  Çıktı: manual-tests\output\gun16-7-iz-collector-ve-iki-kopya.txt" -ForegroundColor DarkGray
}
