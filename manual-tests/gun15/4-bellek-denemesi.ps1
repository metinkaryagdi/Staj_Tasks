# Kontrol listesi 4: bellek sınırı denemesi. Collector'ın bellek sınırı bilerek düşürülür, uzun yük testi (saniyede 50
# fatura, 10 dakika, simülatörün varsayılan oranları) çalıştırılır ve sınıra ulaşılınca ne olduğu gözlenir.
#   .\manual-tests\gun15\4-bellek-denemesi.ps1 -LimitMib 200 -SpikeMib 50
# Yumuşak sınır = LimitMib - SpikeMib: memory_limiter Collector'ın heap'i bunu aşınca gelen veriyi reddeder. Değerler
# uzun testte (1-uzun-yuk.ps1) ölçülen boştaki ve en yüksek heap'e göre seçilir: yumuşak sınır ikisinin arasında.
#
# Yalnız bu deneme için:
#   - monitoring/otel-collector/config.yaml'daki limit_mib ve spike_limit_mib değiştirilir; deneme bitince (hata olsa
#     da) dosya eski haline döner, Collector yeniden başlatılır ve açılış logundaki sınır satırı kaydedilir.
#   - İki uygulamada OpenTelemetry'nin kendi tanılama logu (self-diagnostics) açılır: OTLP gönderiminin hataları konsol
#     loguna yazılmaz, yalnız bu loga düşer. Ayar dosyası ve compose eki output\gun15-4-tanilama altında üretilir; deneme
#     bitince uygulamalar eksiz yeniden başlatılır.
# Gözlenenler: Collector'ın reddettiği span'ler ve metrik noktaları, Collector'ın logu, iki uygulamanın konsol logu ve
# tanılama logu, metriklerin Prometheus'ta görünmediği dakikalar ve alarm, gönderilmeyen fatura, red penceresinin içinde
# ve dışında dakika başına gönderilen fatura (veritabanındaki processed_at).
param([Parameter(Mandatory)][int]$LimitMib, [Parameter(Mandatory)][int]$SpikeMib, [string]$Name = 'bellek')

. "$PSScriptRoot\_common.ps1"
if ($SpikeMib -ge $LimitMib) { throw "spike_limit_mib ($SpikeMib) limit_mib'den ($LimitMib) küçük olmalı." }

$prefix = "gun15-4-$Name"
$out = Join-Path $OutputDir "$prefix.txt"
$report = [Collections.Generic.List[string]]::new()
function Write-Line([string]$Text) { Write-Host $Text; $report.Add($Text) }

Write-Title "Kontrol listesi 4: bellek sınırı denemesi (limit_mib $LimitMib, spike_limit_mib $SpikeMib)"
Write-Line "Deneme sınırı: limit_mib $LimitMib, spike_limit_mib $SpikeMib (yumuşak sınır $($LimitMib - $SpikeMib) MiB heap); normal değer 1600 / 400."
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

$since = Get-UtcStamp
try {
    [IO.File]::WriteAllText($config, $lowered, [Text.UTF8Encoding]::new($false))
    Use-Gun10Volumes "gun15-$Name"
    Invoke-Compose @('up', '-d', 'alertmanager', 'alert-receiver')
    & "$PSScriptRoot\1-uzun-yuk.ps1" -Name $Name -SkipIdle -SkipCount -ComposeFile $override

    Write-Title 'Uygulamalar ve faturalar'
    $runId = @(Get-ServiceRows 'SELECT DISTINCT customer_code FROM invoices;')[0]
    $run = Get-Content (Join-Path $OutputDir "gun15-1-$Name.txt") -Encoding UTF8
    $run | Select-Object -First 5 | ForEach-Object { Write-Line $_ }

    # Red pencereleri: Collector'ın logunda yumuşak sınırın aşıldığı ve altına inildiği anlar.
    $windows = @(); $openAt = $null; $soft = 0; $hard = 0; $resumed = 0; $refusing = 0
    foreach ($l in Get-Content (Join-Path $OutputDir "gun15-1-$Name-limiter-log.txt") -Encoding UTF8) {
        if ($l -notmatch '^(\S+Z)') { continue }
        $at = [DateTimeOffset]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
        if ($l -match 'above soft limit') { $soft++ }
        if ($l -match 'Refusing data') { $refusing++ }
        if ($l -match 'above hard limit') { $hard++ }
        if ($l -match 'Refusing data') { if (-not $openAt) { $openAt = $at } }
        elseif ($l -match 'back within limits') { $resumed++; if ($openAt) { $windows += , @($openAt, $at); $openAt = $null } }
    }
    if ($openAt) { $windows += , @($openAt, [DateTimeOffset]::UtcNow) }
    Write-Line ''
    Write-Line "Collector logu: 'above soft limit' $soft satır (GC zorlaması ve red), 'Refusing data' $refusing satır, 'above hard limit' $hard satır, 'back within limits' $resumed satır; red penceresi $($windows.Count)."
    foreach ($w in $windows) { Write-Line ('  {0}-{1} UTC ({2})' -f $w[0].ToString('HH:mm:ss'), $w[1].ToString('HH:mm:ss'), (Format-Duration ($w[1] - $w[0]).TotalSeconds)) }
    $sample = @(Get-Content (Join-Path $OutputDir "gun15-1-$Name-limiter-log.txt") -Encoding UTF8 | Where-Object { $_ -match 'soft limit|hard limit|within limits' } | Select-Object -First 3)
    foreach ($l in $sample) { Write-Line "  örnek: $l" }

    # Faturalar: hepsi gönderildi mi; dakika başına gönderim red penceresinin içinde ve dışında.
    $statuses = @(Get-ServiceRows "SELECT status, count(*) FROM invoices WHERE customer_code = '$runId' GROUP BY status ORDER BY status;")
    $open = [int]@(Get-ServiceRows "SELECT count(*) FROM erp_outbox o JOIN invoices i ON i.invoice_number = o.invoice_number WHERE i.customer_code = '$runId' AND o.status <> 'Tamamlandı';")[0]
    Write-Line ''
    Write-Line "Faturalar ($runId): $($statuses -join '; '); outbox'ta tamamlanmamış kayıt: $open"
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $perMinute = @(Get-ServiceRows @"
SELECT extract(epoch FROM date_trunc('minute', o.processed_at))::bigint, count(*)
FROM erp_outbox o JOIN invoices i ON i.invoice_number = o.invoice_number
WHERE i.customer_code = '$runId' AND o.processed_at IS NOT NULL GROUP BY 1 ORDER BY 1;
"@ | ForEach-Object { $c = $_.Split('|'); [pscustomobject]@{ At = [DateTimeOffset]::FromUnixTimeSeconds([long]$c[0]); Count = [int]$c[1] } })
    # İlk ve son dakika yarım olabilir: karşılaştırmaya girmez. Bir dakika, red penceresiyle en az 30 sn kesişiyorsa
    # "içinde" sayılır.
    $full = @($perMinute | Select-Object -Skip 1 | Select-Object -SkipLast 1)
    foreach ($m in $full) {
        $overlap = 0.0
        foreach ($w in $windows) {
            $a = [math]::Max($m.At.ToUnixTimeSeconds(), $w[0].ToUnixTimeSeconds()); $b = [math]::Min($m.At.AddMinutes(1).ToUnixTimeSeconds(), $w[1].ToUnixTimeSeconds())
            if ($b -gt $a) { $overlap += $b - $a }
        }
        $m | Add-Member Inside ($overlap -ge 30)
    }
    $in = @($full | Where-Object Inside); $outside = @($full | Where-Object { -not $_.Inside })
    Write-Line 'Dakika başına gönderimi biten fatura (veritabanı, processed_at; ilk ve son dakika hariç):'
    if ($in.Count) { Write-Line ('  Red penceresinin içinde: ort. {0:N1} ({1} dakika, en az {2}, en çok {3})' -f ($in | Measure-Object Count -Average).Average, $in.Count, ($in | Measure-Object Count -Minimum).Minimum, ($in | Measure-Object Count -Maximum).Maximum) }
    if ($outside.Count) { Write-Line ('  Dışında:                 ort. {0:N1} ({1} dakika, en az {2}, en çok {3})' -f ($outside | Measure-Object Count -Average).Average, $outside.Count, ($outside | Measure-Object Count -Minimum).Minimum, ($outside | Measure-Object Count -Maximum).Maximum) }
    $perMinute | Select-Object @{ n = 'Minute'; e = { $_.At.ToString('o') } }, Count, Inside |
        Export-Csv (Join-Path $OutputDir "$prefix-dakika.csv") -NoTypeInformation -Encoding UTF8

    # Uygulamaların konsol logu: OpenTelemetry ya da Collector'a gönderimle ilgili satır var mı.
    Write-Line ''
    Write-Line 'Uygulamaların konsol logu (yük başından sonuna):'
    foreach ($svc in 'invoice-service', 'erp-simulator') {
        Push-Location $RepoRoot
        $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $lines = @(& docker compose logs $svc --no-log-prefix 2>$null | ForEach-Object { "$_" }) }
        finally { $ErrorActionPreference = $previous; Pop-Location }
        $otel = @($lines | Where-Object { $_ -match 'OpenTelemetry|OTLP|otel-collector|4317|grpc|Exporter' })
        $otel | Set-Content (Join-Path $OutputDir "$prefix-$svc-konsol-otel.txt") -Encoding UTF8
        Write-Line ("  {0}: {1} satır; OpenTelemetry / OTLP / Collector geçen satır: {2}" -f $svc, $lines.Count, $otel.Count)
        foreach ($l in $otel | Select-Object -First 3) { Write-Line "    $l" }
    }

    # Tanılama logu (self-diagnostics): OTLP gönderiminin hataları.
    Write-Line ''
    Write-Line 'OpenTelemetry tanılama logu (self-diagnostics, Warning ve üstü):'
    foreach ($svc in 'invoice-service', 'erp-simulator') {
        $files = @(Get-ChildItem (Join-Path $diag $svc) -File -ErrorAction SilentlyContinue)
        $lines = @($files | ForEach-Object { Get-Content $_.FullName -Encoding UTF8 } | Where-Object { $_ -match '\S' -and $_ -notmatch '^\x00+$' })
        Write-Line ("  {0}: {1} dosya, {2} satır" -f $svc, $files.Count, $lines.Count)
        $lines | ForEach-Object { ($_ -replace '^\S+\s+', '') -replace '\d+', 'N' } | Group-Object | Sort-Object Count -Descending |
            Select-Object -First 5 | ForEach-Object { Write-Line ("    {0} kez: {1}" -f $_.Count, ($_.Name.Substring(0, [math]::Min(220, $_.Name.Length)))) }
    }

    # Metrikler de aynı sınırdan geçer: reddedilince Prometheus'ta servisin metrikleri görünmez.
    Write-Line ''
    Write-Line "Prometheus'ta servislerin metrikleri (target_info, dakikalık örnek):"
    $startEpoch = [DateTimeOffset]::UtcNow.AddHours(-6).ToUnixTimeSeconds()
    foreach ($job in 'invoice-service', 'erp-simulator') {
        $q = [Uri]::EscapeDataString("count_over_time(target_info{job=`"$job`"}[1m])")
        $r = Invoke-RestMethod "$PrometheusUrl/api/v1/query_range?query=$q&start=$startEpoch&end=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())&step=60" -TimeoutSec 30
        $values = @($r.data.result | ForEach-Object { $_.values } | ForEach-Object { [long]$_[0] })
        $first = ($values | Measure-Object -Minimum).Minimum; $lastV = ($values | Measure-Object -Maximum).Maximum
        $missing = @(); if ($values.Count) { for ($t = $first; $t -le $lastV; $t += 60) { if ($values -notcontains $t) { $missing += $t } } }
        Write-Line ("  {0}: görünmediği dakika {1}{2}" -f $job, $missing.Count, $(if ($missing.Count) { ' (' + (($missing | Select-Object -First 1 | ForEach-Object { [DateTimeOffset]::FromUnixTimeSeconds($_).ToString('HH:mm') }) + '-' + ($missing | Select-Object -Last 1 | ForEach-Object { [DateTimeOffset]::FromUnixTimeSeconds($_).ToString('HH:mm') })) + ' UTC arası)' } else { '' }))
    }
    $alerts = @(Get-ReceiverLines $since | Where-Object { $_ -match 'MetrikToplanamiyor' })
    Write-Line "Alarm alıcısında MetrikToplanamiyor satırı: $($alerts.Count)"
    foreach ($l in $alerts | Select-Object -First 6) { Write-Line "  $l" }
}
finally {
    Write-Step 'Bellek sınırı eski değerine döndürülüyor'
    [IO.File]::WriteAllBytes($config, $original)
    Use-Gun10Volumes "gun15-$Name"
    Invoke-Compose @('up', '-d', '--force-recreate', 'otel-collector', 'invoice-service', 'erp-simulator')
    Start-Sleep -Seconds 5
    $back = @(docker logs staj-tasks-otel-collector-1 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'Memory limiter configured' }) | Select-Object -Last 1
    $same = [Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($config))) -eq
        [Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash($original))
    $back | Set-Content (Join-Path $OutputDir "$prefix-donus.txt") -Encoding UTF8
    Write-Line ''
    Write-Line "Dönüş: config.yaml denemeden önceki haliyle aynı: $same; Collector açılış logu: $back"
    Write-Line 'Uygulamalar tanılama eki olmadan yeniden başlatıldı.'
    $report | Set-Content $out -Encoding UTF8
    Write-Host "  Çıktı: manual-tests\output\$prefix.txt (+ -dakika.csv, -donus.txt, -*-konsol-otel.txt, -tanilama\)" -ForegroundColor DarkGray
}
