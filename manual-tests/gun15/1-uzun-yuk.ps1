# Kontrol listesi 1 ve 2: uzun yük testi (saniyede 50 fatura, 10 dakika, simülatörün varsayılan oranları) boyunca
# Collector'ın belleği ve bellekteki trace'ler; koşunun sonunda sistem boştayken bellekte bekleyen trace sayısı; sonra
# sayım (2-sayim.ps1).
#   .\manual-tests\gun15\1-uzun-yuk.ps1
#   .\manual-tests\gun15\1-uzun-yuk.ps1 -Name uzun-2
# Koşu kendi boş volume'leriyle (staj-tasks_*-db-data-gun15-<Name>) açılır; volume doluysa durur. Collector ve Jaeger
# yeniden başlatılır (ikisi de bellekte tutar, Collector'ın sayaçları 0'dan başlar). Simülatör appsettings.json'daki
# (varsayılan) ayarlarla açılır; script simülatörün ayarını değiştirmez.
#
# Ölçümler, yükten 30 sn önce başlayıp koşunun sonuna kadar:
#   docker stats, 5 sn'de bir: Collector ve Jaeger'ın belleği (-bellek.csv).
#   Collector'ın kendi metrikleri, 15 sn'de bir (-collector-metrikleri.txt): bellekteki trace sayısı, yeni gelen trace
#   sayacı, heap, reddedilen span ve metrik noktaları, erken atılan trace'ler, Jaeger'a gönderilemeyen span'ler.
#   Collector'ın logu: bellek sınırının devreye girdiği ve çıktığı anlar (-limiter-log.txt).
# Kayıtlar bittikten (kuyruk boş, simülatörde bekleyen haber yok) sonra decision_wait + 60 sn beklenir: koşunun bütün
# trace'leri karara bağlanır. Sonra sistem boştadır: bir mutabakat çalışmasının bitmesi beklenir (bütün worker'lar en az
# bir kez çalışmış olsun) ve bellekte bekleyen trace sayısı ile yeni trace hızı okunur (kontrol listesi 2).
#
# Sayımdan sonra kontrol listesi 3'ün görüntüleri alınır (3-ekran.ps1).
#
# -SkipIdle: boştaki ölçüm yapılmaz. -SkipCount: sayım ve görüntüler yapılmaz. -ComposeFile: compose'a eklenecek dosya
# (bellek sınırı denemesinde kullanılır). -WaitSeconds: son kararlar için beklenen süre (varsayılan decision_wait + 60 sn;
# yalnız script'in kendisini kısa bir koşuyla denemek için kısaltılır).
param([int]$Rate = 50, [string]$Duration = '10m', [string]$Name = 'uzun', [switch]$SkipIdle, [switch]$SkipCount,
    [string]$ComposeFile = '', [int]$WaitSeconds = 0)

. "$PSScriptRoot\_common.ps1"

$prefix = "gun15-1-$Name"
$out = Join-Path $OutputDir "$prefix.txt"
$report = [Collections.Generic.List[string]]::new()
function Write-Line([string]$Text) { Write-Host $Text; $report.Add($Text) }

Write-Title "Uzun yük testi (saniyede $Rate fatura, $Duration, simülatörün varsayılan oranları)"
Use-Gun10Volumes "gun15-$Name"
if ($ComposeFile) { $env:COMPOSE_FILE += ";$ComposeFile" }
Clear-SimulatorEnv
# --force-recreate: servisler yeni veritabanlarına bağlanıp migration'larını orada çalıştırsın.
Invoke-Compose @('up', '-d', '--build', '--force-recreate', 'invoice-db', 'erp-db', 'invoice-service', 'erp-simulator')
Wait-Health $ServiceUrl
Wait-Health $SimulatorUrl
Show-SimulatorSettings
$settingsLine = Get-SimulatorLog | Where-Object { $_ -match 'Simulator settings:' } | Select-Object -Last 1
$existing = [int]@(Get-ServiceRows 'SELECT count(*) FROM invoices;')[0]
if ($existing -ne 0) { throw "gun15-$Name volume'ü boş değil ($existing fatura); docker volume rm ile silip yeniden çalıştırın ya da -Name verin." }
Invoke-Compose @('up', '-d', '--force-recreate', 'otel-collector', 'jaeger')
Invoke-Compose @('up', '-d', 'prometheus')
Start-Sleep -Seconds 5
$limit = (docker inspect staj-tasks-otel-collector-1 --format '{{.HostConfig.Memory}}')
$configured = @(docker logs staj-tasks-otel-collector-1 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'Memory limiter configured' }) | Select-Object -Last 1
Write-Host "  Collector container bellek sınırı: $([long]$limit / 1MB) MiB; $configured" -ForegroundColor DarkGray

$stop = Join-Path $OutputDir "$prefix.stop"
$metricsFile = Join-Path $OutputDir "$prefix-collector-metrikleri.txt"
Remove-Item $stop, $metricsFile -ErrorAction SilentlyContinue
$statsJob = Start-Job -ArgumentList $stop -ScriptBlock {
    param($stop)
    while (-not (Test-Path $stop)) {
        $t = [DateTimeOffset]::UtcNow
        docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' staj-tasks-otel-collector-1 staj-tasks-jaeger-1 2>$null |
            ForEach-Object { "$($t.ToUnixTimeSeconds())|$_" }
        Start-Sleep -Seconds 5
    }
}
# Her ölçüm "# T <unix saniye>" satırıyla başlar; yalnız Collector'ın kendi otelcol_ satırları yazılır.
$metricsJob = Start-Job -ArgumentList $stop, $metricsFile, $RepoRoot -ScriptBlock {
    param($stop, $file, $root)
    Set-Location $root
    while (-not (Test-Path $stop)) {
        $t = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $lines = @(docker compose exec -T prometheus wget -qO- http://otel-collector:8888/metrics 2>$null | Where-Object { $_ -match '^otelcol_' })
        Add-Content $file (@("# T $t") + $lines) -Encoding UTF8
        Start-Sleep -Seconds 15
    }
}
Start-Sleep -Seconds 30

$runId = "GUN15-$Name-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
$loadStart = [DateTimeOffset]::UtcNow
$result = Invoke-LoadTest @{ BASE_URLS = 'http://invoice-service:8080'; RATE = $Rate; DURATION = $Duration; RUN_ID = $runId }
$loadEnd = [DateTimeOffset]::UtcNow

Write-Step 'Kuyruğun boşalması ve haberlerin gönderilmesi bekleniyor'
$watch = [Diagnostics.Stopwatch]::StartNew()
$last = -1
while ($true) {
    $queued = [int]@(Get-ServiceRows "SELECT count(*) FROM erp_outbox o JOIN invoices i ON i.invoice_number = o.invoice_number WHERE i.customer_code = '$runId' AND o.status = 'Bekliyor';")[0]
    $hooks = [int]@(Get-ErpRows "SELECT count(*) FROM webhook_deliveries WHERE status IN ('Pending', 'Waiting');")[0]
    if ($queued -eq 0 -and $hooks -eq 0) { break }
    $now = [math]::Round($queued / 500)
    if ($now -ne $last) { Write-Host ('  {0}: kuyrukta {1} kayıt, simülatörde {2} haber bekliyor' -f (Format-Duration $watch.Elapsed.TotalSeconds), $queued, $hooks) -ForegroundColor DarkGray }
    $last = $now
    if ($watch.Elapsed.TotalHours -gt 5) { throw "5 saat içinde kuyruk boşalmadı ($queued kayıt, $hooks haber)." }
    Start-Sleep -Seconds 15
}
$settled = [DateTimeOffset]::UtcNow
Write-Host ("  {0}: kuyruk boş, simülatörde bekleyen haber yok" -f (Format-Duration $watch.Elapsed.TotalSeconds))

$wait = if ($WaitSeconds -gt 0) { $WaitSeconds } else { $DecisionWaitSeconds + 60 }
Write-Step "Collector'ın son kararları için $wait sn bekleniyor"
Start-Sleep -Seconds $wait
$idleFrom = [DateTimeOffset]::UtcNow

$recon = $null
if (-not $SkipIdle) {
    # Boşta da çalışan worker'lar: kuyruk sorgusu (250 ms), metrik okuma (15 sn), simülatörün haber kuyruğu (200 ms) ve
    # mutabakat (60 dk). Mutabakatın bir çalışması bitene kadar beklenir; bitişinden 30 sn sonra okunur (uygulamaların
    # gönderimi 5 sn'de bir, Collector'ın ölçümü 15 sn'de bir).
    Write-Step 'Boşta: bir mutabakat çalışmasının bitmesi bekleniyor'
    $lastRun = [long]@(Get-ServiceRows 'SELECT coalesce(max(id), 0) FROM reconciliation_runs;')[0]
    $reconWatch = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $row = @(Get-ServiceRows "SELECT id, extract(epoch FROM started_at)::numeric(16,3), extract(epoch FROM finished_at)::numeric(16,3), status FROM reconciliation_runs WHERE id > $lastRun AND finished_at IS NOT NULL ORDER BY id LIMIT 1;")
        if ($row.Count -and $row[0]) {
            $c = $row[0].Split('|')
            $inv = [Globalization.CultureInfo]::InvariantCulture
            $recon = [pscustomobject]@{ Id = $c[0]; Started = [DateTimeOffset]::FromUnixTimeMilliseconds([long]([double]::Parse($c[1], $inv) * 1000))
                Finished = [DateTimeOffset]::FromUnixTimeMilliseconds([long]([double]::Parse($c[2], $inv) * 1000)); Status = $c[3] }
            break
        }
        if ($reconWatch.Elapsed.TotalMinutes -gt 75) { throw '75 dakika içinde mutabakat çalışmadı.' }
        Start-Sleep -Seconds 15
    }
    Write-Host ("  Mutabakat #{0} {1}-{2} UTC ({3})" -f $recon.Id, $recon.Started.ToString('HH:mm:ss'), $recon.Finished.ToString('HH:mm:ss'), $recon.Status)
    Start-Sleep -Seconds 30
}
$idleTo = [DateTimeOffset]::UtcNow

New-Item $stop -ItemType File | Out-Null
$samples = @(Receive-Job $statsJob -Wait -AutoRemoveJob | ForEach-Object {
    $p = "$_".Split('|')
    [pscustomobject]@{ At = [DateTimeOffset]::FromUnixTimeSeconds([long]$p[0]); Name = $p[1] -replace '^staj-tasks-|-1$', ''; Mem = ConvertTo-MiB $p[3] }
})
Receive-Job $metricsJob -Wait -AutoRemoveJob | Out-Null
Remove-Item $stop -ErrorAction SilentlyContinue

# Collector öldürüldüyse (container sınırı) bellekteki izler kaybolmuştur.
$state = (docker inspect staj-tasks-otel-collector-1 --format '{{.State.Status}}|{{.State.OOMKilled}}|{{.State.StartedAt}}').Split('|')

# Bellek sınırının veri reddettiği aralıklar (_common.ps1, Get-RefusalWindows).
$limiterLines = @(docker logs staj-tasks-otel-collector-1 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'memorylimiter|Memory usage|Memory limiter' })
$limiterLines | Set-Content (Join-Path $OutputDir "$prefix-limiter-log.txt") -Encoding UTF8
$hard = @($limiterLines | Where-Object { $_ -match 'above hard limit' }).Count
$windows = @(Get-RefusalWindows $limiterLines)
$periods = $windows.Count
$engaged = [double]($windows | ForEach-Object { ($_.To - $_.From).TotalSeconds } | Measure-Object -Sum).Sum

$snapshots = @(Read-CollectorSnapshots $metricsFile)
$lastLines = $snapshots[-1].Lines
$refused = Get-MetricSum $lastLines 'otelcol_receiver_refused_spans_total'
$refusedMetrics = Get-MetricSum $lastLines 'otelcol_receiver_refused_metric_points_total'
$accepted = Get-MetricSum $lastLines 'otelcol_receiver_accepted_spans_total'
$tooEarly = Get-MetricSum $lastLines 'otelcol_processor_tail_sampling_sampling_trace_dropped_too_early_total'
$exportFailed = Get-MetricSum $lastLines 'otelcol_exporter_send_failed_spans_total'
$kept = Get-MetricSum $lastLines 'otelcol_processor_tail_sampling_global_count_traces_sampled_total\{.*sampled="true"'
$dropped = Get-MetricSum $lastLines 'otelcol_processor_tail_sampling_global_count_traces_sampled_total\{.*sampled="false"'
$onMemory = @($snapshots | ForEach-Object { [pscustomobject]@{ At = $_.At; Traces = Get-MetricSum $_.Lines 'otelcol_processor_tail_sampling_sampling_traces_on_memory'
    New = Get-MetricSum $_.Lines 'otelcol_processor_tail_sampling_new_trace_id_received_total'; Heap = (Get-MetricSum $_.Lines 'otelcol_process_runtime_heap_alloc_bytes') / 1MB } })
$maxOnMemory = $onMemory | Sort-Object Traces -Descending | Select-Object -First 1
$maxHeap = $onMemory | Sort-Object Heap -Descending | Select-Object -First 1

Write-Title 'Koşu ve Collector'
Write-Line "Koşu: $runId; yük $($loadStart.ToString('HH:mm:ss'))-$($loadEnd.ToString('HH:mm:ss')) UTC, k6 istek $($result.requests), kabul $($result.accepted)."
Write-Line "Simülatör: $(($settingsLine -replace '^.*Simulator settings:', '').Trim())"
Write-Line "Kayıtlar $($settled.ToString('HH:mm:ss')) UTC'de bitti ($(Format-Duration ($settled - $loadStart).TotalSeconds) yük başından)."
Write-Line "Collector container bellek sınırı $([long]$limit / 1MB) MiB; $configured"
Write-Line "Collector sonda: durum $($state[0]), OOMKilled $($state[1]), başlama $($state[2])."
Write-Line ''
Write-Line "Collector belleği (docker stats, 5 sn'de bir):"
$col = @($samples | Where-Object Name -eq 'otel-collector')
$idle = @($col | Where-Object { $_.At -lt $loadStart })
$busy = @($col | Where-Object { $_.At -ge $loadStart -and $_.At -le $settled })
$after = @($col | Where-Object { $_.At -gt $settled })
foreach ($part in @(@('Yükten önce', $idle), @('Yük başından kayıtların bitmesine', $busy), @('Sonrası, koşunun sonuna', $after))) {
    $s = @($part[1])
    if ($s.Count -eq 0) { continue }
    Write-Line ('  {0,-40} ort. {1,6:N0} MiB, en çok {2,6:N0} MiB ({3} örnek)' -f $part[0], ($s | Measure-Object Mem -Average).Average, ($s | Measure-Object Mem -Maximum).Maximum, $s.Count)
}
$peak = $col | Sort-Object Mem -Descending | Select-Object -First 1
if ($peak) { Write-Line ('  En yüksek: {0:N0} MiB, {1} UTC (yük başından {2})' -f $peak.Mem, $peak.At.ToString('HH:mm:ss'), (Format-Duration ($peak.At - $loadStart).TotalSeconds)) }
if ($maxHeap) { Write-Line ('  En yüksek heap (memory_limiter bunu ölçer): {0:N0} MiB, {1} UTC (yük başından {2})' -f $maxHeap.Heap, $maxHeap.At.ToString('HH:mm:ss'), (Format-Duration ($maxHeap.At - $loadStart).TotalSeconds)) }
$jae = @($samples | Where-Object Name -eq 'jaeger')
if ($jae.Count -gt 1) { Write-Line ('Jaeger belleği: ilk örnek {0:N0} MiB, en çok {1:N0} MiB, son örnek {2:N0} MiB.' -f $jae[0].Mem, ($jae | Measure-Object Mem -Maximum).Maximum, $jae[-1].Mem) }
Write-Line ''
Write-Line 'Bellek sınırı (memory_limiter, Collector logu):'
Write-Line ("  Devreye girdiği süre: {0} ({1} kez); sert sınırın aşıldığı log satırı: {2}" -f (Format-Duration $engaged), $periods, $hard)
if ($windows.Count) {
    Write-Line ('    ilki {0} UTC, sonuncusu {1} UTC bitti; en uzun {2}' -f $windows[0].From.ToString('HH:mm:ss'), $windows[-1].To.ToString('HH:mm:ss'),
        (Format-Duration ($windows | ForEach-Object { ($_.To - $_.From).TotalSeconds } | Measure-Object -Maximum).Maximum))
}
Write-Line ''
Write-Line "Collector'ın sayaçları (koşunun başından son ölçüme):"
Write-Line "  Kabul edilen span: $accepted; bellek sınırı yüzünden reddedilen span: $refused, metrik noktası: $refusedMetrics"
Write-Line ("  Bellekte en çok trace: {0} ({1} UTC, yük başından {2}); num_traces dolduğu için erken atılan trace: {3}" -f $maxOnMemory.Traces, $maxOnMemory.At.ToString('HH:mm:ss'), (Format-Duration ($maxOnMemory.At - $loadStart).TotalSeconds), $tooEarly)
Write-Line "  Jaeger'a gönderilemeyen span: $exportFailed"
if (($kept + $dropped) -gt 0) {
    Write-Line ('  Karar verilen trace: {0}; saklanan {1} ({2:P1}), örneklemeyle atılan {3} ({4:P1})' -f ($kept + $dropped), $kept, ($kept / ($kept + $dropped)), $dropped, ($dropped / ($kept + $dropped)))
}

if ($recon) {
    # Boştaki pencere: koşunun bütün trace'leri karara bağlandıktan sonrası. Yeni trace hızı pencerenin ilk ve son
    # ölçümü arasındaki sayaç farkından.
    $win = @($onMemory | Where-Object { $_.At -ge $idleFrom -and $_.At -le $idleTo })
    $firstAfter = @($onMemory | Where-Object { $_.At -ge $recon.Finished.AddSeconds(15) }) | Select-Object -First 1
    Write-Line ''
    Write-Line "Sistem boştayken (kontrol listesi 2), $($idleFrom.ToString('HH:mm:ss'))-$($idleTo.ToString('HH:mm:ss')) UTC:"
    Write-Line ("  Mutabakat #{0} {1}-{2} UTC ({3})" -f $recon.Id, $recon.Started.ToString('HH:mm:ss'), $recon.Finished.ToString('HH:mm:ss'), $recon.Status)
    if ($win.Count -ge 2) {
        $dt = ($win[-1].At - $win[0].At).TotalSeconds
        Write-Line ('  Bellekte bekleyen trace: en çok {0}, en az {1}' -f ($win | Measure-Object Traces -Maximum).Maximum, ($win | Measure-Object Traces -Minimum).Minimum)
        if ($firstAfter) { Write-Line ('  Mutabakattan sonraki ilk ölçümde ({0} UTC): {1}' -f $firstAfter.At.ToString('HH:mm:ss'), $firstAfter.Traces) }
        Write-Line ('  Yeni trace: {0} ({1:N0} sn içinde; {2:N3} trace/sn)' -f ($win[-1].New - $win[0].New), $dt, (($win[-1].New - $win[0].New) / $dt))
    }
}

$report | Set-Content $out -Encoding UTF8
$samples | Select-Object @{ n = 'At'; e = { $_.At.ToString('o') } }, Name, Mem |
    Export-Csv (Join-Path $OutputDir "$prefix-bellek.csv") -NoTypeInformation -Encoding UTF8
Write-Host "  Çıktı: manual-tests\output\$prefix.txt (+ -bellek.csv, -collector-metrikleri.txt, -limiter-log.txt)" -ForegroundColor DarkGray

if (-not $SkipCount) {
    & "$PSScriptRoot\2-sayim.ps1" -RunId $runId -Name $Name
    & "$PSScriptRoot\3-ekran.ps1" -Name $Name
}
