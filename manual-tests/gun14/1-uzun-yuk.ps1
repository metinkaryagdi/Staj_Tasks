# Kontrol listesi 2: uzun yük testi (saniyede 50 fatura, 10 dakika) boyunca Collector'ın belleği, bellek sınırının
# devreye girip girmediği, Collector'ın attığı ya da reddettiği span'ler; sonunda sayım (2-sayim.ps1).
#   .\manual-tests\gun14\1-uzun-yuk.ps1
#   .\manual-tests\gun14\1-uzun-yuk.ps1 -Name uzun-2
# Koşu kendi boş volume'leriyle (staj-tasks_*-db-data-gun14-<Name>) açılır; volume doluysa durur. Collector ve Jaeger
# yeniden başlatılır (ikisi de bellekte tutar, Collector'ın sayaçları 0'dan başlar).
#
# Simülatör Gün 13'teki gibi Success 30, ServerError 40 ile açılır (kalıcı olarak Başarısız fatura çıksın diye); diğer
# oranlar varsayılandır. Koşu bitince simülatör varsayılan ayarlarına döner.
#
# Ölçümler, yükten 30 sn önce başlayıp son kararlara kadar:
#   docker stats, 5 sn'de bir: Collector ve Jaeger'ın belleği (-bellek.csv).
#   Collector'ın kendi metrikleri, 15 sn'de bir (-collector-metrikleri.txt): reddedilen span'ler, bellekteki trace sayısı,
#   num_traces dolduğu için erken atılan trace'ler, Jaeger'a gönderilemeyen span'ler.
#   Collector'ın logu: bellek sınırının devreye girdiği ve çıktığı anlar (-limiter-log.txt).
# Kayıtlar bittikten (kuyruk boş, simülatörde bekleyen haber yok) sonra decision_wait + 60 sn beklenir.
param([int]$Rate = 50, [string]$Duration = '10m', [string]$Name = 'uzun')

. "$PSScriptRoot\_common.ps1"

$prefix = "gun14-1-$Name"
$out = Join-Path $OutputDir "$prefix.txt"
$report = [Collections.Generic.List[string]]::new()
function Write-Line([string]$Text) { Write-Host $Text; $report.Add($Text) }

Write-Title "Kontrol listesi 2: uzun yük testi (saniyede $Rate fatura, $Duration)"
Use-Gun10Volumes "gun14-$Name"
# --force-recreate: servisler yeni veritabanlarına bağlanıp migration'larını orada çalıştırsın.
Invoke-Compose @('up', '-d', '--build', '--force-recreate', 'invoice-db', 'erp-db', 'invoice-service', 'erp-simulator')
Wait-Health $ServiceUrl
Wait-Health $SimulatorUrl
$existing = [int]@(Get-ServiceRows 'SELECT count(*) FROM invoices;')[0]
if ($existing -ne 0) { throw "gun14-$Name volume'ü boş değil ($existing fatura); docker volume rm ile silip yeniden çalıştırın ya da -Name verin." }
Invoke-Compose @('up', '-d', '--force-recreate', 'otel-collector', 'jaeger')
Invoke-Compose @('up', '-d', 'prometheus')
Start-Sleep -Seconds 5
$limit = (docker inspect staj-tasks-otel-collector-1 --format '{{.HostConfig.Memory}}')
Write-Host "  Collector container bellek sınırı: $([long]$limit / 1MB) MiB" -ForegroundColor DarkGray

Restart-Simulator @{ Simulator__Rates__Success = 30; Simulator__Rates__ServerError = 40 }
$stop = Join-Path $env:TEMP "$prefix.stop"
$metricsFile = Join-Path $OutputDir "$prefix-collector-metrikleri.txt"
Remove-Item $stop, $metricsFile -ErrorAction SilentlyContinue
try {
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

    $runId = "GUN14-$Name-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
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
}
finally { Restart-Simulator }

$wait = $DecisionWaitSeconds + 60
Write-Step "Collector'ın son kararları için $wait sn bekleniyor"
Start-Sleep -Seconds $wait
New-Item $stop -ItemType File | Out-Null
$samples = @(Receive-Job $statsJob -Wait -AutoRemoveJob | ForEach-Object {
    $p = "$_".Split('|')
    [pscustomobject]@{ At = [DateTimeOffset]::FromUnixTimeSeconds([long]$p[0]); Name = $p[1] -replace '^staj-tasks-|-1$', ''; Mem = ConvertTo-MiB $p[3] }
})
Receive-Job $metricsJob -Wait -AutoRemoveJob | Out-Null

# Collector öldürüldüyse (container sınırı) bellekteki izler kaybolmuştur.
$state = (docker inspect staj-tasks-otel-collector-1 --format '{{.State.Status}}|{{.State.OOMKilled}}|{{.State.StartedAt}}').Split('|')

# Bellek sınırı: memory_limiter yumuşak sınırı aşınca "above soft limit", altına inince "back within limits" yazar.
$limiterLines = @(docker logs staj-tasks-otel-collector-1 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'memorylimiter|Memory usage' })
$limiterLines | Set-Content (Join-Path $OutputDir "$prefix-limiter-log.txt") -Encoding UTF8
$engaged = 0.0; $periods = 0; $openAt = $null; $hard = 0
foreach ($l in $limiterLines) {
    if ($l -notmatch '^(\S+Z)') { continue }
    $at = [DateTimeOffset]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
    if ($l -match 'above hard limit') { $hard++ }
    if ($l -match 'above soft limit|above hard limit') { if (-not $openAt) { $openAt = $at; $periods++ } }
    elseif ($l -match 'back within limits' -and $openAt) { $engaged += ($at - $openAt).TotalSeconds; $openAt = $null }
}
if ($openAt) { $engaged += ([DateTimeOffset]::UtcNow - $openAt).TotalSeconds }

# Son ölçümdeki sayaçlar (Collector koşunun başında yeniden başladı, sayaçlar 0'dan).
$snapshots = (Get-Content $metricsFile -Raw -Encoding UTF8) -split '(?m)^# T ' | Where-Object { $_.Trim() }
$lastLines = @(($snapshots[-1] -split "`r?`n") | Select-Object -Skip 1)
$refused = Get-MetricSum $lastLines 'otelcol_receiver_refused_spans_total'
$accepted = Get-MetricSum $lastLines 'otelcol_receiver_accepted_spans_total'
$tooEarly = Get-MetricSum $lastLines 'otelcol_processor_tail_sampling_sampling_trace_dropped_too_early_total'
$exportFailed = Get-MetricSum $lastLines 'otelcol_exporter_send_failed_spans_total'
$kept = Get-MetricSum $lastLines 'otelcol_processor_tail_sampling_global_count_traces_sampled_total\{.*sampled="true"'
$dropped = Get-MetricSum $lastLines 'otelcol_processor_tail_sampling_global_count_traces_sampled_total\{.*sampled="false"'
$maxOnMemory = ($snapshots | ForEach-Object { Get-MetricSum (($_ -split "`r?`n") | Select-Object -Skip 1) 'otelcol_processor_tail_sampling_sampling_traces_on_memory' } | Measure-Object -Maximum).Maximum

Write-Title 'Koşu ve Collector'
Write-Line "Koşu: $runId; yük $($loadStart.ToString('HH:mm:ss'))-$($loadEnd.ToString('HH:mm:ss')) UTC, k6 istek $($result.requests), kabul $($result.accepted)."
Write-Line "Simülatör: Success 30, ServerError 40 (diğerleri varsayılan). Kayıtlar $($settled.ToString('HH:mm:ss')) UTC'de bitti ($(Format-Duration ($settled - $loadStart).TotalSeconds) yük başından); sayım $wait sn sonra."
Write-Line "Collector container bellek sınırı $([long]$limit / 1MB) MiB; sonda durum $($state[0]), OOMKilled $($state[1]), başlama $($state[2])."
Write-Line ''
Write-Line "Collector belleği (docker stats, 5 sn'de bir):"
$col = @($samples | Where-Object Name -eq 'otel-collector')
$idle = @($col | Where-Object { $_.At -lt $loadStart })
$busy = @($col | Where-Object { $_.At -ge $loadStart -and $_.At -le $settled })
$after = @($col | Where-Object { $_.At -gt $settled })
foreach ($part in @(@('Yükten önce (boşta)', $idle), @('Yük başından kayıtların bitmesine', $busy), @('Sonrası, son kararlara kadar', $after))) {
    $s = @($part[1])
    if ($s.Count -eq 0) { continue }
    Write-Line ('  {0,-40} ort. {1,6:N0} MiB, en çok {2,6:N0} MiB ({3} örnek)' -f $part[0], ($s | Measure-Object Mem -Average).Average, ($s | Measure-Object Mem -Maximum).Maximum, $s.Count)
}
$peak = $col | Sort-Object Mem -Descending | Select-Object -First 1
if ($peak) { Write-Line ('  En yüksek: {0:N0} MiB, {1} UTC (yük başından {2})' -f $peak.Mem, $peak.At.ToString('HH:mm:ss'), (Format-Duration ($peak.At - $loadStart).TotalSeconds)) }
$jae = @($samples | Where-Object Name -eq 'jaeger')
if ($jae.Count -gt 1) { Write-Line ('Jaeger belleği: ilk örnek {0:N0} MiB, en çok {1:N0} MiB, son örnek {2:N0} MiB.' -f $jae[0].Mem, ($jae | Measure-Object Mem -Maximum).Maximum, $jae[-1].Mem) }
Write-Line ''
Write-Line 'Bellek sınırı (memory_limiter, Collector logu):'
Write-Line ("  Devreye girdiği süre: {0} ({1} kez); sert sınırın aşıldığı log satırı: {2}" -f (Format-Duration $engaged), $periods, $hard)
Write-Line ''
Write-Line "Collector'ın sayaçları (koşunun başından son ölçüme):"
Write-Line "  Kabul edilen span: $accepted; bellek sınırı yüzünden reddedilen span: $refused"
Write-Line "  num_traces dolduğu için karar süresi dolmadan atılan trace: $tooEarly; bellekteki en çok trace: $maxOnMemory"
Write-Line "  Jaeger'a gönderilemeyen span: $exportFailed"
if (($kept + $dropped) -gt 0) {
    Write-Line ('  Karar verilen trace: {0}; saklanan {1} ({2:P1}), örneklemeyle atılan {3} ({4:P1})' -f ($kept + $dropped), $kept, ($kept / ($kept + $dropped)), $dropped, ($dropped / ($kept + $dropped)))
}

$report | Set-Content $out -Encoding UTF8
$samples | Select-Object @{ n = 'At'; e = { $_.At.ToString('o') } }, Name, Mem |
    Export-Csv (Join-Path $OutputDir "$prefix-bellek.csv") -NoTypeInformation -Encoding UTF8
Write-Host "  Çıktı: manual-tests\output\$prefix.txt (+ -bellek.csv, -collector-metrikleri.txt, -limiter-log.txt)" -ForegroundColor DarkGray

& "$PSScriptRoot\2-sayim.ps1" -RunId $runId -Name $Name
