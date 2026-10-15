# Kontrol listesi 1 ve 4: yük testi (saniyede 50 fatura, 2 dakika) sonrası hangi faturaların izi saklandı, ve yük
# sırasında Collector'ın belleği.
#   .\manual-tests\gun13\1-yuk-ornekleme.ps1
#   .\manual-tests\gun13\1-yuk-ornekleme.ps1 -Name yuk-2
# Koşu kendi boş volume'leriyle (staj-tasks_*-db-data-gun13-<Name>) açılır; volume doluysa durur. Collector ve Jaeger
# yeniden başlatılır (ikisi de bellekte tutar), böylece yalnız bu koşunun izleri sayılır.
#
# Kalıcı olarak Başarısız fatura varsayılan simülatör oranlarıyla neredeyse hiç çıkmaz (ERP'nin kaydetmediği sorunlu
# cevap %25, 10 denemenin hepsinin böyle olması 0,25^10). Bu koşu için simülatör Success 30, ServerError 40 ile açılır
# (kaydetmeyen sorunlu cevap %55); diğer oranlar varsayılandır. Koşu bitince simülatör varsayılan ayarlarına döner.
#
# Kayıtlar bittikten (kuyruk boş, simülatörde bekleyen haber yok) sonra Collector'ın karar süresi (decision_wait) ve
# gönderim payı kadar beklenir; ondan önce sayılan bir iz henüz kararını beklemektedir. Sayımı 1-sayim.ps1 yapar.
# Collector ve Jaeger'ın belleği yükten 30 sn önce başlayarak son kararlara kadar 5 sn'de bir ölçülür.
# Çıktı output\gun13-1-<Name>.txt (koşu, bellek), -bellek.csv, ve 1-sayim.ps1'in -sayim.txt / -faturalar.csv'si.
param([int]$Rate = 50, [string]$Duration = '2m', [string]$Name = 'yuk')

. "$PSScriptRoot\_common.ps1"

$out = Join-Path $OutputDir "gun13-1-$Name.txt"
$report = [Collections.Generic.List[string]]::new()
function Write-Line([string]$Text) { Write-Host $Text; $report.Add($Text) }

function ConvertTo-MiB([string]$Text) {
    if ($Text -notmatch '^([\d.]+)\s*([KMG]i?B|B)') { return 0 }
    $v = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
    switch -regex ($Matches[2]) { '^G' { $v * 1024 } '^M' { $v } '^K' { $v / 1024 } default { $v / 1MB } }
}

Write-Title "Kontrol listesi 1 ve 4: yük altında örnekleme (saniyede $Rate fatura, $Duration)"
Use-Gun10Volumes "gun13-$Name"
# --force-recreate: servisler yeni veritabanlarına bağlanıp migration'larını orada çalıştırsın.
Invoke-Compose @('up', '-d', '--build', '--force-recreate', 'invoice-db', 'erp-db', 'invoice-service', 'erp-simulator')
Wait-Health $ServiceUrl
Wait-Health $SimulatorUrl
$existing = [int]@(Get-ServiceRows 'SELECT count(*) FROM invoices;')[0]
if ($existing -ne 0) { throw "gun13-$Name volume'ü boş değil ($existing fatura); docker volume rm ile silip yeniden çalıştırın ya da -Name verin." }
Invoke-Compose @('up', '-d', '--force-recreate', 'otel-collector', 'jaeger')
# Collector'ın sayaçları Prometheus container'ından okunur (compose ağında otel-collector:8888).
Invoke-Compose @('up', '-d', 'prometheus')
Start-Sleep -Seconds 5

Restart-Simulator @{ Simulator__Rates__Success = 30; Simulator__Rates__ServerError = 40 }
# Script hata verse de simülatör varsayılan ayarlarına döner.
try {
    # docker stats arka planda, 5 sn'de bir: yükten 30 sn önce başlar (boştaki bellek), kararlar verilene kadar sürer.
    $stop = Join-Path $env:TEMP "gun13-$Name.stop"
    Remove-Item $stop -ErrorAction SilentlyContinue
    $job = Start-Job -ArgumentList $stop -ScriptBlock {
        param($stop)
        while (-not (Test-Path $stop)) {
            $t = [DateTimeOffset]::UtcNow
            docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' staj-tasks-otel-collector-1 staj-tasks-jaeger-1 2>$null |
                ForEach-Object { "$($t.ToUnixTimeSeconds())|$_" }
            Start-Sleep -Seconds 5
        }
    }
    Start-Sleep -Seconds 30

    $runId = "GUN13-$Name-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $loadStart = [DateTimeOffset]::UtcNow
    $result = Invoke-LoadTest @{ BASE_URLS = 'http://invoice-service:8080'; RATE = $Rate; DURATION = $Duration; RUN_ID = $runId }
    $loadEnd = [DateTimeOffset]::UtcNow

    # Kayıtlar bitti = kuyrukta bekleyen kayıt ve simülatörde gönderilmeyi bekleyen haber yok. Karar haberi simülatörde
    # kaybolan faturalar (LostDecisionRate) İşleme Alındı'da kalır, mutabakatı bekler (60 dk); mutabakat burada beklenmez.
    Write-Step 'Kuyruğun boşalması ve haberlerin gönderilmesi bekleniyor'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $last = -1
    while ($true) {
        $queued = [int]@(Get-ServiceRows "SELECT count(*) FROM erp_outbox o JOIN invoices i ON i.invoice_number = o.invoice_number WHERE i.customer_code = '$runId' AND o.status = 'Bekliyor';")[0]
        $hooks = [int]@(Get-ErpRows "SELECT count(*) FROM webhook_deliveries WHERE status IN ('Pending', 'Waiting');")[0]
        if ($queued -eq 0 -and $hooks -eq 0) { break }
        $now = [math]::Round($queued / 100)
        if ($now -ne $last) { Write-Host ('  {0,6:N0} sn: kuyrukta {1} kayıt, simülatörde {2} haber bekliyor' -f $watch.Elapsed.TotalSeconds, $queued, $hooks) -ForegroundColor DarkGray }
        $last = $now
        if ($watch.Elapsed.TotalMinutes -gt 90) { throw "90 dk içinde kuyruk boşalmadı ($queued kayıt, $hooks haber)." }
        Start-Sleep -Seconds 15
    }
    $settled = [DateTimeOffset]::UtcNow
    Write-Host ("  {0}: kuyruk boş, simülatörde bekleyen haber yok" -f (Format-Duration $watch.Elapsed.TotalSeconds))
}
finally { Restart-Simulator }

# Simülatörün yeniden başlaması da kayıt üretmez; son span'in kararı için decision_wait + gönderim payı (SDK 5 sn, Collector
# kararları saniyede bir işler) beklenir.
$wait = $DecisionWaitSeconds + 60
Write-Step "Collector'ın son kararları için $wait sn bekleniyor"
Start-Sleep -Seconds $wait
New-Item $stop -ItemType File | Out-Null
$samples = @(Receive-Job $job -Wait -AutoRemoveJob | ForEach-Object {
    $p = "$_".Split('|')
    [pscustomobject]@{ At = [DateTimeOffset]::FromUnixTimeSeconds([long]$p[0]); Name = $p[1] -replace '^staj-tasks-|-1$', ''; Mem = ConvertTo-MiB $p[3] }
})

# Collector'ın kendi sayaçları (Collector koşunun başında yeniden başlatıldı, sayaçlar 0'dan başladı): karar verilen
# bütün trace'lerden kaçı saklandı, kaçı atıldı. Faturaların ve worker sorgularının trace'leri birlikte sayılır.
$metrics = @(Push-Location $RepoRoot; try { & docker compose exec -T prometheus wget -qO- http://otel-collector:8888/metrics } finally { Pop-Location })
$metrics | Set-Content (Join-Path $OutputDir "gun13-1-$Name-collector-metrikleri.txt") -Encoding UTF8
function Get-CollectorCounter([string]$Pattern) {
    $line = $metrics | Where-Object { $_ -match "^$Pattern" } | Select-Object -First 1
    if (-not $line) { return $null }
    [long][double]::Parse(($line -split ' ')[-1], [Globalization.CultureInfo]::InvariantCulture)
}
$kept = Get-CollectorCounter 'otelcol_processor_tail_sampling_global_count_traces_sampled_total\{.*sampled="true"'
$dropped = Get-CollectorCounter 'otelcol_processor_tail_sampling_global_count_traces_sampled_total\{.*sampled="false"'
$received = Get-CollectorCounter 'otelcol_processor_tail_sampling_new_trace_id_received_total'
$tooEarly = Get-CollectorCounter 'otelcol_processor_tail_sampling_sampling_trace_dropped_too_early_total'


Write-Title 'Koşu ve Collector belleği'
Write-Line "Koşu: $runId; yük $($loadStart.ToString('HH:mm:ss'))-$($loadEnd.ToString('HH:mm:ss')) UTC, k6 istek $($result.requests), kabul $($result.accepted)."
Write-Line "Simülatör: Success 30, ServerError 40 (diğerleri varsayılan). Kayıtlar $($settled.ToString('HH:mm:ss')) UTC'de bitti; sayım $([int]$wait) sn sonra."
Write-Line ''
Write-Line "Collector belleği (docker stats, 5 sn'de bir):"
$col = @($samples | Where-Object Name -eq 'otel-collector')
$idle = @($col | Where-Object { $_.At -lt $loadStart })
$load = @($col | Where-Object { $_.At -ge $loadStart -and $_.At -le $loadEnd.AddSeconds(60) })
$after = @($col | Where-Object { $_.At -gt $loadEnd.AddSeconds(60) })
foreach ($part in @(@('Yükten önce (boşta)', $idle), @('Yük boyunca + 60 sn (dünkü ölçümle aynı pencere)', $load), @('Sonrası, son kararlara kadar', $after))) {
    $s = @($part[1])
    if ($s.Count -eq 0) { continue }
    Write-Line ('  {0,-50} ort. {1,6:N0} MiB, en çok {2,6:N0} MiB ({3} örnek)' -f $part[0], ($s | Measure-Object Mem -Average).Average, ($s | Measure-Object Mem -Maximum).Maximum, $s.Count)
}
$peak = $col | Sort-Object Mem -Descending | Select-Object -First 1
if ($peak) { Write-Line ('  En yüksek: {0:N0} MiB, {1} UTC' -f $peak.Mem, $peak.At.ToString('HH:mm:ss')) }
$jae = @($samples | Where-Object Name -eq 'jaeger')
if ($jae.Count -gt 1) { Write-Line ('Jaeger belleği: ilk örnek {0:N0} MiB, son örnek {1:N0} MiB.' -f $jae[0].Mem, $jae[-1].Mem) }
Write-Line ''
Write-Line "Collector'ın sayaçları (koşunun başından sayım anına):"
if ($null -ne $kept -and $null -ne $dropped -and ($kept + $dropped) -gt 0) {
    Write-Line ('  Karar verilen trace: {0}; saklanan {1} ({2:P1}), atılan {3} ({4:P1})' -f ($kept + $dropped), $kept, ($kept / ($kept + $dropped)), $dropped, ($dropped / ($kept + $dropped)))
}
else { Write-Line '  Karar sayaçları okunamadı.' }
Write-Line "  Gelen yeni trace: $received; karar süresi dolmadan bellekten atılan (num_traces dolduğu için): $tooEarly"

$report | Set-Content $out -Encoding UTF8
$samples | Select-Object @{ n = 'At'; e = { $_.At.ToString('o') } }, Name, Mem |
    Export-Csv (Join-Path $OutputDir "gun13-1-$Name-bellek.csv") -NoTypeInformation -Encoding UTF8
Write-Host "  Çıktı: manual-tests\output\gun13-1-$Name.txt (+ -bellek.csv)" -ForegroundColor DarkGray

& "$PSScriptRoot\1-sayim.ps1" -RunId $runId -Name $Name
