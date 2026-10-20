# Kontrol listesi 1 ve 2: bellek sınırı denemesi, metrikler ayrı Collector'dayken. İz Collector'ının bellek sınırı bilerek
# düşürülür, uzun yük testi (saniyede 50 fatura, 10 dakika, simülatörün varsayılan oranları) çalıştırılır; Collector izleri
# reddederken metriklerin Prometheus'ta kesintisiz göründüğü, MetrikToplanamiyor'un tetiklenmediği ve CollectorIzReddediyor'un
# tetiklendiği gözlenir. Deneme bitince sınır eski değerine döner ve ret alarmının çözülmesi beklenir.
#   .\manual-tests\gun16\4-bellek-denemesi.ps1 -LimitMib 400 -SpikeMib 100
# Yumuşak sınır = LimitMib - SpikeMib (iz Collector'ının heap'i bunu aşınca gelen span'ler reddedilir). Metrik Collector'ının
# sınırı değişmez.
#
# Yalnız bu deneme için:
#   - monitoring/otel-collector/config.yaml'daki limit_mib ve spike_limit_mib değiştirilir; deneme bitince (hata olsa da)
#     dosya eski haline döner, Collector yeniden başlatılır ve açılış logundaki sınır satırı kaydedilir.
#   - İki uygulamada OpenTelemetry'nin kendi tanılama logu (self-diagnostics) açılır: OTLP gönderiminin hataları (iz mi metrik
#     mi) konsol loguna yazılmaz, yalnız bu loga düşer. Ayar dosyası ve compose eki output\gun16-4-<Name>-tanilama altında
#     üretilir; deneme bitince uygulamalar eksiz yeniden başlatılır.
#   - Ret ilk görüldükten -ScreenshotAfterMinutes dakika sonra panonun ekran görüntüsü alınır (Grafana, yükün başlamasından
#     30 sn önceden o ana kadar: yeni veritabanıyla); o anki alarmlar yanına yazılır.
# Metriklerin sürekliliğine yükten 30 sn önceden sınırın geri alınmasına kadar bakılır (uygulamalar o anda tanılama eki
# kaldırılarak yeniden başlatılır).
# -WaitSeconds: kuyruk boşaldıktan sonra sınır geri alınmadan önce beklenen süre (1-uzun-yuk.ps1'e geçer); bu denemede
# kararların sonucu sayılmadığı için kısa.
param([Parameter(Mandatory)][int]$LimitMib, [Parameter(Mandatory)][int]$SpikeMib, [string]$Name = 'bellek',
    [int]$Rate = 50, [string]$Duration = '10m', [int]$ScreenshotAfterMinutes = 10, [int]$WaitSeconds = 60,
    [int]$ResolveTimeoutMinutes = 15)

. "$PSScriptRoot\_common.ps1"
if ($SpikeMib -ge $LimitMib) { throw "spike_limit_mib ($SpikeMib) limit_mib'den ($LimitMib) küçük olmalı." }

$prefix = "gun16-4-$Name"
$out = Join-Path $OutputDir "$prefix.txt"
$report = [Collections.Generic.List[string]]::new()
function Write-Line([string]$Text) { Write-Host $Text; $report.Add($Text) }

Write-Title "Kontrol listesi 1-2: bellek sınırı denemesi (iz Collector'ı limit_mib $LimitMib, spike_limit_mib $SpikeMib)"
Write-Line "Deneme sınırı: limit_mib $LimitMib, spike_limit_mib $SpikeMib (yumuşak sınır $($LimitMib - $SpikeMib) MiB heap); normal değer 1600 / 400. Karar süresi $DecisionWaitSeconds sn."
$config = Join-Path $RepoRoot 'monitoring\otel-collector\config.yaml'
$original = [IO.File]::ReadAllBytes($config)
$text = [Text.Encoding]::UTF8.GetString($original)
$lowered = $text -replace '(?m)^(\s+limit_mib:) \d+', "`$1 $LimitMib" -replace '(?m)^(\s+spike_limit_mib:) \d+', "`$1 $SpikeMib"
if ($lowered -eq $text) { throw 'config.yaml''da limit_mib / spike_limit_mib bulunamadı.' }

$diag = Join-Path $OutputDir "$prefix-tanilama"
Remove-Item $diag -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force (Join-Path $diag 'invoice-service'), (Join-Path $diag 'erp-simulator') | Out-Null
'{ "LogDirectory": "/diag", "FileSize": 32768, "LogLevel": "Warning", "FormatMessage": "true" }' |
    Set-Content (Join-Path $diag 'OTEL_DIAGNOSTICS.json') -Encoding ASCII
$d = $diag -replace '\\', '/'
$override = Join-Path $diag 'compose.tanilama.yml'
@"
services:
  invoice-service:
    volumes:
      - "$d/OTEL_DIAGNOSTICS.json:/app/OTEL_DIAGNOSTICS.json:ro"
      - "$d/invoice-service:/diag"
  erp-simulator:
    volumes:
      - "$d/OTEL_DIAGNOSTICS.json:/app/OTEL_DIAGNOSTICS.json:ro"
      - "$d/erp-simulator:/diag"
"@ | Set-Content $override -Encoding UTF8

# Ekran görüntüsü: ret ilk görüldükten sonra beklenir, görüntü alınır, o anki alarmlar yazılır. Ret hiç görülmezse durdurma
# dosyasıyla biter.
$png = Join-Path $OutputDir "$prefix-pano.png"
$shotInfo = Join-Path $OutputDir "$prefix-pano.txt"
$shotStop = Join-Path $OutputDir "$prefix-pano.stop"
$loadStartFile = Join-Path $OutputDir "gun16-1-$Name.yuk-basi"
Remove-Item $png, $shotInfo, $shotStop, $loadStartFile -ErrorAction SilentlyContinue
$shotJob = Start-Job -ArgumentList $PSScriptRoot, $png, $shotInfo, $shotStop, $ScreenshotAfterMinutes, $loadStartFile -ScriptBlock {
    param($root, $png, $info, $stop, $after, $loadStartFile)
    . "$root\_common.ps1"
    $first = $null
    while (-not (Test-Path $stop)) {
        try { $v = Get-PrometheusValue 'sum(increase(otelcol_receiver_refused_spans_total{job="otel-collector"}[1m]))' } catch { $v = $null }
        if (-not $first -and $v -gt 0) { $first = [DateTimeOffset]::UtcNow }
        if ($first -and ([DateTimeOffset]::UtcNow - $first).TotalMinutes -ge $after) {
            $at = [DateTimeOffset]::UtcNow
            $start = [DateTimeOffset]::FromUnixTimeSeconds([long](Get-Content $loadStartFile -Raw).Trim()).AddSeconds(-30)
            $from = $start.ToUnixTimeMilliseconds(); $to = $at.ToUnixTimeMilliseconds()
            Save-Screenshot "$GrafanaUrl/d/fatura-servisi?orgId=1&from=$from&to=$to&kiosk" $png 1800 2600
            $alerts = @(Get-ActiveAlerts | ForEach-Object { "$($_.Alarm) $($_.Durum) (başlangıç $($_.Başlangıç))" })
            @("Ret ilk görüldü: $($first.ToString('HH:mm:ss')) UTC", "Görüntü: $($at.ToString('HH:mm:ss')) UTC (pano $($start.ToString('HH:mm:ss'))-$($at.ToString('HH:mm:ss')) UTC)",
                "O andaki alarmlar (Prometheus): $(if ($alerts.Count) { $alerts -join '; ' } else { 'yok' })",
                "O andaki son 1 dakikada reddedilen span: $v") | Set-Content $info -Encoding UTF8
            return
        }
        Start-Sleep -Seconds 15
    }
}

$since = Get-UtcStamp
$sinceAt = [DateTimeOffset]::UtcNow
$restoredAt = $null
try {
    [IO.File]::WriteAllText($config, $lowered, [Text.UTF8Encoding]::new($false))
    Use-Gun10Volumes "gun16-$Name"
    Invoke-Compose @('up', '-d', 'alertmanager', 'alert-receiver')
    & "$PSScriptRoot\1-uzun-yuk.ps1" -Name $Name -Rate $Rate -Duration $Duration -SkipIdle -SkipCount -ComposeFile $override -WaitSeconds $WaitSeconds
    $checkTo = [DateTimeOffset]::UtcNow

    Write-Title 'Collector, metrikler ve alarmlar'
    $runId = @(Get-ServiceRows 'SELECT DISTINCT customer_code FROM invoices;')[0]
    $run = @(Get-Content (Join-Path $OutputDir "gun16-1-$Name.txt") -Encoding UTF8)
    $run | Select-Object -First 5 | ForEach-Object { Write-Line $_ }
    $run | Where-Object { $_ -match 'reddedilen span' } | ForEach-Object { Write-Line $_.Trim() }

    # Red aralıkları (Gün 15 _common.ps1, Get-RefusalWindows) ve logdaki satır sayıları.
    $limiterLog = @(Get-Content (Join-Path $OutputDir "gun16-1-$Name-limiter-log.txt") -Encoding UTF8)
    $count = { param($Pattern) @($limiterLog | Where-Object { $_ -match $Pattern }).Count }
    $windows = @(Get-RefusalWindows $limiterLog)
    $seconds = @($windows | ForEach-Object { ($_.To - $_.From).TotalSeconds })
    Write-Line ("Collector logu: GC zorlaması (yumuşak sınır) {0}, 'Refusing data' {1}, 'above hard limit' {2}, 'back within limits' {3} satır." -f
        (& $count 'above soft limit. Forcing a GC'), (& $count 'Refusing data'), (& $count 'above hard limit'), (& $count 'back within limits'))
    if ($windows.Count) {
        Write-Line ('Red aralıkları: {0}; ilki {1} UTC başladı, sonuncusu {2} UTC bitti; toplam {3}, en uzun {4}.' -f $windows.Count,
            $windows[0].From.ToString('HH:mm:ss'), $windows[-1].To.ToString('HH:mm:ss'), (Format-Duration ($seconds | Measure-Object -Sum).Sum),
            (Format-Duration ($seconds | Measure-Object -Maximum).Maximum))
        $windows | Select-Object @{ n = 'From'; e = { $_.From.ToString('o') } }, @{ n = 'To'; e = { $_.To.ToString('o') } } |
            Export-Csv (Join-Path $OutputDir "$prefix-red-araliklari.csv") -NoTypeInformation -Encoding UTF8
    }
    else { Write-Line 'Red aralığı yok: sınıra ulaşılmadı.' }

    # Metrikler: yükten 30 sn önceden (1-uzun-yuk.ps1 ölçümlere o anda başlar) sınırın geri alınmasına kadar, 5 sn'lik adımlarla.
    $loadLine = $run | Where-Object { $_ -match 'yük (\d\d:\d\d:\d\d)-' } | Select-Object -First 1
    $null = $loadLine -match 'yük (\d\d:\d\d:\d\d)-'
    $loadStart = [DateTimeOffset]::Parse("$($sinceAt.UtcDateTime.ToString('yyyy-MM-dd'))T$($Matches[1])Z", [Globalization.CultureInfo]::InvariantCulture)
    if ($loadStart -lt $sinceAt) { $loadStart = $loadStart.AddDays(1) }
    $checkFrom = $loadStart.AddSeconds(-30)
    Write-Line ''
    Write-Line "Prometheus'ta servislerin metrikleri, $($checkFrom.ToString('HH:mm:ss'))-$($checkTo.ToString('HH:mm:ss')) UTC (5 sn adım; son 10 sn içinde target_info örneği):"
    foreach ($job in 'invoice-service', 'erp-simulator') {
        $c = Test-MetricContinuity $job $checkFrom $checkTo
        Write-Line ("  {0}: {1} adım, örneği olmayan adım {2}{3}" -f $job, $c.Steps, $c.Missing.Count,
            $(if ($c.Missing.Count) { ' (ilki ' + $c.Missing[0].ToString('HH:mm:ss') + ', sonuncusu ' + $c.Missing[-1].ToString('HH:mm:ss') + ' UTC)' } else { '' }))
    }
    $up = @(Get-PrometheusRange 'min_over_time(up{job="otel-collector-metrics"}[10s])' $checkFrom $checkTo 5 | ForEach-Object { $_.values } | Where-Object { [double]$_[1] -lt 1 })
    Write-Line "  Prometheus'un metrik Collector'ını toplayamadığı adım: $($up.Count)"
    if ($windows.Count) {
        $inside = 0
        foreach ($job in 'invoice-service', 'erp-simulator') {
            foreach ($w in $windows) { $inside += @((Test-MetricContinuity $job $w.From $w.To).Missing).Count }
        }
        Write-Line "  Red aralıklarının içinde örneği olmayan adım (iki servis): $inside"
    }

    # Alarmlar: Prometheus'taki durumları (pending dahil) ve alıcının logu.
    Write-Line ''
    Write-Line "Alarmlar, $($checkFrom.ToString('HH:mm:ss'))-$($checkTo.ToString('HH:mm:ss')) UTC:"
    foreach ($alert in 'MetrikToplanamiyor', 'CollectorIzReddediyor') {
        $states = @(Get-AlertStates $alert $checkFrom $checkTo)
        if ($states.Count) { foreach ($s in $states) { Write-Line ("  {0} {1}{2}: {3}-{4} UTC" -f $alert, $s.State, $(if ($s.Job) { " ($($s.Job))" } else { '' }), $s.First.ToString('HH:mm:ss'), $s.Last.ToString('HH:mm:ss')) } }
        else { Write-Line "  $alert : Prometheus'ta hiç pending ya da firing olmadı" }
    }
    foreach ($l in @(Get-ReceiverLines $since | Where-Object { $_ -match 'alertname=(MetrikToplanamiyor|CollectorIzReddediyor) ' })) {
        Write-Line ("  alıcı: " + ($l -replace ' summary=.*$', ''))
    }
    if (Test-Path $shotInfo) { Write-Line ''; Write-Line 'Pano ekran görüntüsü:'; Get-Content $shotInfo -Encoding UTF8 | ForEach-Object { Write-Line "  $_" } }
    else { Write-Line ''; Write-Line 'Pano ekran görüntüsü alınmadı (ret görülmedi ya da süre dolmadı).' }

    # Faturalar: hepsi gönderildi mi.
    $statuses = @(Get-ServiceRows "SELECT status, count(*) FROM invoices WHERE customer_code = '$runId' GROUP BY status ORDER BY status;")
    $open = [int]@(Get-ServiceRows "SELECT count(*) FROM erp_outbox o JOIN invoices i ON i.invoice_number = o.invoice_number WHERE i.customer_code = '$runId' AND o.status <> 'Tamamlandı';")[0]
    Write-Line ''
    Write-Line "Faturalar ($runId): $($statuses -join '; '); outbox'ta tamamlanmamış kayıt: $open"

    # Tanılama logu (self-diagnostics): OTLP gönderiminin hataları; iz ve metrik gönderimi ayrı sayılır.
    Write-Line ''
    Write-Line 'OpenTelemetry tanılama logu (self-diagnostics, Warning ve üstü):'
    foreach ($svc in 'invoice-service', 'erp-simulator') {
        $files = @(Get-ChildItem (Join-Path $diag $svc) -File -ErrorAction SilentlyContinue)
        $lines = @($files | ForEach-Object { Get-Content $_.FullName -Encoding UTF8 } | Where-Object { $_ -match '\S' -and $_ -notmatch '^\x00+$' })
        $traceErr = @($lines | Where-Object { $_ -match 'TraceService/Export' }).Count
        $metricErr = @($lines | Where-Object { $_ -match 'MetricsService/Export' }).Count
        Write-Line ("  {0}: {1} dosya, {2} satır; başarısız iz gönderimi {3}, başarısız metrik gönderimi {4}" -f $svc, $files.Count, $lines.Count, $traceErr, $metricErr)
        $lines | ForEach-Object { ($_ -replace '^\S+\s+', '') -replace '\d+', 'N' } | Group-Object | Sort-Object Count -Descending |
            Select-Object -First 3 | ForEach-Object { Write-Line ("    {0} kez: {1}" -f $_.Count, ($_.Name.Substring(0, [math]::Min(220, $_.Name.Length)))) }
    }
}
finally {
    New-Item $shotStop -ItemType File -Force | Out-Null
    Receive-Job $shotJob -Wait -AutoRemoveJob -ErrorAction Continue | Out-Null
    Remove-Item $shotStop -ErrorAction SilentlyContinue

    Write-Step 'Bellek sınırı eski değerine döndürülüyor'
    [IO.File]::WriteAllBytes($config, $original)
    Use-Gun10Volumes "gun16-$Name"
    $restoredAt = [DateTimeOffset]::UtcNow
    $restoredStamp = Get-UtcStamp
    Invoke-Compose @('up', '-d', '--force-recreate', 'otel-collector', 'invoice-service', 'erp-simulator')
    Start-Sleep -Seconds 5
    $back = @(docker logs staj-tasks-otel-collector-1 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'Memory limiter configured' }) | Select-Object -Last 1
    $same = [Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($config))) -eq
        [Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash($original))
    $back | Set-Content (Join-Path $OutputDir "$prefix-donus.txt") -Encoding UTF8
    Write-Line ''
    Write-Line "Dönüş ($($restoredAt.ToString('HH:mm:ss')) UTC): config.yaml denemeden önceki haliyle aynı: $same; Collector açılış logu: $back"
    Write-Line 'Uygulamalar tanılama eki olmadan yeniden başlatıldı.'

    # Kontrol listesi 2: ret alarmının çözülmesi (son retten 5 dk sonra beklenir).
    Write-Step "CollectorIzReddediyor'un çözülmesi bekleniyor (en çok $ResolveTimeoutMinutes dk)"
    $fired = @(Get-ReceiverLines $since | Where-Object { $_ -match 'status=firing alertname=CollectorIzReddediyor ' }).Count
    if ($fired) {
        $resolved = Wait-ReceiverLine 'CollectorIzReddediyor' 'resolved' $restoredStamp ($ResolveTimeoutMinutes * 60)
        if ($resolved) {
            $at = [DateTimeOffset]::Parse($resolved.Substring(0, 23).Replace(' ', 'T') + 'Z', [Globalization.CultureInfo]::InvariantCulture)
            Write-Line ("Ret alarmı çözüldü: alıcıya {0} UTC (sınırın dönüşünden {1} sonra): {2}" -f $at.ToString('HH:mm:ss'), (Format-Duration ($at - $restoredAt).TotalSeconds), ($resolved -replace ' summary=.*$', ''))
        }
        else { Write-Line "Ret alarmı $ResolveTimeoutMinutes dk içinde çözülmedi." }
    }
    else { Write-Line 'Ret alarmı tetiklenmediği için çözülmesi beklenmedi.' }
    $later = @(Get-ReceiverLines $restoredStamp | Where-Object { $_ -match 'alertname=MetrikToplanamiyor ' })
    Write-Line "Sınırın dönüşünden sonra alıcıda MetrikToplanamiyor satırı: $($later.Count)"
    $report | Set-Content $out -Encoding UTF8
    Write-Host "  Çıktı: manual-tests\output\$prefix.txt (+ -pano.png, -pano.txt, -red-araliklari.csv, -donus.txt, -tanilama\)" -ForegroundColor DarkGray
}
