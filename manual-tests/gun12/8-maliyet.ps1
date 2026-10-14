# Raporun maliyet bölümü: izlemenin ek kaynak kullanımı. Aynı yük iki kez çalıştırılır: OpenTelemetry SDK'sı kapalı
# (compose.izsiz.yml, OTEL_SDK_DISABLED=true: ne iz ne metrik) ve açık; sıra -Order ile verilir (ilk koşu soğuk
# container'larla başlar, sıra etkisini görmek için ters sırayla da çalıştırılır). Her koşu kendi boş volume'leriyle
# (staj-tasks_*-db-data-gun12-<Name>-izsiz / -izli) açılır; volume doluysa durur. Çıktı output\gun12-8-<Name>.txt.
#   .\manual-tests\gun12\8-maliyet.ps1
#   .\manual-tests\gun12\8-maliyet.ps1 -Order izli,izsiz -Name maliyet-ters
# Ölçülenler: k6'nın POST /api/v1/invoices cevap süresi; yük boyunca ve bitiminden 60 sn sonrasına kadar 5 sn'de bir
# docker stats (CPU, bellek); izli koşuda Jaeger'ın belleği (koşudan önce yeniden başlatılır, izler bellekte tutulur) ve
# rastgele 20 faturanın izindeki span sayısı. Sonunda yığın normal Gün 12 volume'leriyle yeniden açılır.
param([int]$Rate = 50, [string]$Duration = '2m', [ValidateSet('izsiz', 'izli')][string[]]$Order = @('izsiz', 'izli'),
    [string]$Name = 'maliyet')

. "$PSScriptRoot\_common.ps1"

$containers = 'invoice-service', 'erp-simulator', 'otel-collector', 'jaeger'
$out = Join-Path $OutputDir "gun12-8-$Name.txt"
$report = [Collections.Generic.List[string]]::new()
function Write-Line([string]$Text) { Write-Host $Text; $report.Add($Text) }

function ConvertTo-MiB([string]$Text) {
    if ($Text -notmatch '^([\d.]+)\s*([KMG]i?B|B)') { return 0 }
    $v = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
    switch -regex ($Matches[2]) { '^G' { $v * 1024 } '^M' { $v } '^K' { $v / 1024 } default { $v / 1MB } }
}

# Yığını verilen etiketin volume'leriyle açar; izsiz koşuda SDK'yı kapatan dosya da eklenir.
function Start-Stack([string]$Label) {
    $env:GUN10_VOL = "gun12-$Name-$Label"
    $files = @((Join-Path $RepoRoot 'docker-compose.yml'), (Join-Path $RepoRoot 'manual-tests\gun10\compose.volumes.yml'))
    if ($Label -eq 'izsiz') { $files += (Join-Path $PSScriptRoot 'compose.izsiz.yml') }
    $env:COMPOSE_FILE = $files -join ';'
    Invoke-Compose @('up', '-d', '--force-recreate', 'invoice-db', 'erp-db', 'invoice-service', 'erp-simulator')
    Wait-Health $ServiceUrl
    Wait-Health $SimulatorUrl
}

function Measure-Run([string]$Label) {
    Write-Title "Maliyet koşusu: $Label (saniyede $Rate fatura, $Duration)"
    Start-Stack $Label
    $existing = [int]@(Get-ServiceRows 'SELECT count(*) FROM invoices;')[0]
    if ($existing -ne 0) { throw "gun12-$Name-$Label volume'ü boş değil ($existing fatura); docker volume rm ile silip yeniden çalıştırın." }
    if ($Label -eq 'izli') { Invoke-Compose @('restart', 'jaeger'); Start-Sleep -Seconds 5 }

    # docker stats arka planda, 5 sn'de bir; k6 bitince 60 sn daha (kuyruk gönderilmeye devam eder).
    $stop = Join-Path $env:TEMP "gun12-maliyet-$Label.stop"
    Remove-Item $stop -ErrorAction SilentlyContinue
    $names = $containers | ForEach-Object { "staj-tasks-$_-1" }
    $job = Start-Job -ArgumentList (, $names), $stop -ScriptBlock {
        param($names, $stop)
        while (-not (Test-Path $stop)) {
            $t = Get-Date
            docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' @names 2>$null | ForEach-Object { "$($t.ToString('HH:mm:ss'))|$_" }
            Start-Sleep -Seconds 5
        }
    }
    $runId = "GUN12-MALIYET-$Label-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $result = Invoke-LoadTest @{ BASE_URLS = 'http://invoice-service:8080'; RATE = $Rate; DURATION = $Duration; RUN_ID = $runId }
    Start-Sleep -Seconds 60
    New-Item $stop -ItemType File | Out-Null
    $samples = @(Receive-Job $job -Wait -AutoRemoveJob | ForEach-Object {
        $p = "$_".Split('|')
        [pscustomobject]@{ Name = $p[1] -replace '^staj-tasks-|-1$', ''; Cpu = [double]::Parse($p[2].TrimEnd('%'), [Globalization.CultureInfo]::InvariantCulture); Mem = ConvertTo-MiB $p[3] }
    })
    $sent = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE customer_code = '$runId' AND status <> 'Bekliyor';")[0]

    $spans = $null
    if ($Label -eq 'izli') {
        $sample = @(Get-ServiceRows "SELECT invoice_number FROM invoices WHERE customer_code = '$runId' AND status <> 'Bekliyor' ORDER BY random() LIMIT 20;")
        $counts = @($sample | ForEach-Object { (Get-InvoiceTrace $_ 30).Spans.Count })
        $spans = [pscustomobject]@{ Ortalama = [math]::Round(($counts | Measure-Object -Average).Average, 1); EnAz = ($counts | Measure-Object -Minimum).Minimum; EnCok = ($counts | Measure-Object -Maximum).Maximum }
    }
    [pscustomobject]@{ Label = $Label; RunId = $runId; Result = $result; Samples = $samples; Sent = $sent; Spans = $spans }
}

$runs = @($Order | ForEach-Object { Measure-Run $_ })

Write-Title 'Sonuç'
Write-Line "Yük: saniyede $Rate fatura, $Duration; sıra: $($Order -join ', '); ölçüm yük boyunca ve bitiminden 60 sn sonrasına kadar 5 sn'de bir."
Write-Line ''
Write-Line 'POST /api/v1/invoices cevap süresi (k6):'
foreach ($r in $runs) {
    $d = $r.Result.durationMs
    Write-Line ("  {0,-6} istek {1}, kabul {2}; p50 {3:N1} ms, p95 {4:N1} ms, p99 {5:N1} ms, en uzun {6:N1} ms; ölçüm sonunda gönderilmiş {7}" -f `
        $r.Label, $r.Result.requests, $r.Result.accepted, $d.p50, $d.p95, $d.p99, $d.max, $r.Sent)
}
Write-Line ''
Write-Line 'Kaynak kullanımı (docker stats; CPU %100 = bir çekirdek):'
Write-Line ('  {0,-16} {1,-6} {2,10} {3,10} {4,12} {5,12}' -f 'Container', 'Koşu', 'CPU ort.', 'CPU en çok', 'Bellek ort.', 'Bellek en çok')
foreach ($c in $containers) {
    foreach ($r in $runs) {
        $s = @($r.Samples | Where-Object { $_.Name -eq $c })
        if ($s.Count -eq 0) { continue }
        Write-Line ('  {0,-16} {1,-6} {2,9:N1}% {3,9:N1}% {4,9:N0} MiB {5,9:N0} MiB' -f $c, $r.Label,
            ($s | Measure-Object Cpu -Average).Average, ($s | Measure-Object Cpu -Maximum).Maximum,
            ($s | Measure-Object Mem -Average).Average, ($s | Measure-Object Mem -Maximum).Maximum)
    }
}
$izli = $runs | Where-Object { $_.Label -eq 'izli' }
$jaeger = @($izli.Samples | Where-Object { $_.Name -eq 'jaeger' })
if ($jaeger.Count -gt 1) {
    Write-Line ''
    Write-Line ("Jaeger belleği (izli koşu, yeniden başlatıldıktan sonra): ilk örnek {0:N0} MiB, son örnek {1:N0} MiB; {2} fatura gönderildi." -f `
        $jaeger[0].Mem, $jaeger[-1].Mem, $izli.Sent)
}
if ($izli.Spans) {
    Write-Line ("Rastgele 20 faturanın izinde span sayısı: ortalama {0}, en az {1}, en çok {2}." -f $izli.Spans.Ortalama, $izli.Spans.EnAz, $izli.Spans.EnCok)
}
$report | Set-Content $out -Encoding UTF8
Write-Host "  Çıktı: manual-tests\output\gun12-8-$Name.txt" -ForegroundColor DarkGray

Write-Step 'Yığın normal Gün 12 volume''leriyle yeniden açılıyor'
Use-Gun10Volumes 'gun12'
Invoke-Compose @('up', '-d', '--force-recreate', 'invoice-db', 'erp-db', 'invoice-service', 'erp-simulator')
