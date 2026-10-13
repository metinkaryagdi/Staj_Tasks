# 2. madde: yük testi sırasında panodaki gönderim hızı simülatör logundaki saniye sayımlarıyla, kuyruk değerleri özet
# API'siyle tutarlı. Önce yük testi ayrı pencerede başlatılır:
#   docker compose run --rm k6
# Sonra, yük sürerken:
#   .\manual-tests\gun11\2-yuk-pano.ps1
# Panonun ekran görüntüsü yük sürerken alınır (http://localhost:3000).
#
# Örnekler simülatördeki ilk POST'tan 60 saniye sonra başlar (panodaki değer son 1 dakikanın ortalamasıdır; o dakika tamamen yük
# içinde olmalıdır), sonra yaklaşık her $IntervalSeconds saniyede bir alınır:
# - Gönderim hızı: panodaki sorgu (son 1 dakikanın saniye ortalaması), simülatör logunda aynı 60 saniyenin saniye sayımlarının
#   (her saniyedeki POST satırı: davranış seçilenler ve hız sınırına takılanlar) ortalamasıyla karşılaştırılır. Fark %10'dan
#   küçükse tutarlı.
# - Kuyruk ve en eski bekleme: Prometheus'taki değerin toplandığı an bulunur (timestamp()); servisin o andan önceki son
#   veritabanı okuması ("Metrics read from the database queued=… oldestQueuedSeconds=…", özet API'sinin aynı sorgusu) logdan
#   okunur. İkisi birebir aynıysa tutarlı. Özet API'si de aynı anda okunur ve yanına yazılır (bilgi için: değer okumadan
#   bu yana geçen birkaç saniyede değişmiş olabilir).
# Sonunda simülatörün yük boyunca logu, saniye başına POST tablosu ve örnek tablosu manual-tests\output altına yazılır.
param([int]$Samples = 16, [int]$IntervalSeconds = 15)

. "$PSScriptRoot\_common.ps1"

Write-Title 'Yük altında pano: gönderim hızı ve kuyruk'

$inv = [Globalization.CultureInfo]::InvariantCulture

function Get-ComposeLog([string]$Service, [int]$Seconds) {
    Push-Location $RepoRoot
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { @(& docker compose logs $Service --no-log-prefix --since "$($Seconds)s" 2>$null | ForEach-Object { "$_" }) }
    finally { $ErrorActionPreference = $previous; Pop-Location }
}

function Test-PostLine([string]$Line) { $Line -match 'ERP request #\d+ .*behavior=' -or $Line -match 'reason=rateLimited' }

# Prometheus'taki değer ve toplandığı an (UTC).
function Get-PrometheusSample([string]$Query) {
    $value = Get-PrometheusValue "max($Query)"
    $at = Get-PrometheusValue "max(timestamp($Query))"
    if ($null -eq $value -or $null -eq $at) { return $null }
    [pscustomobject]@{ Value = $value; At = [DateTimeOffset]::FromUnixTimeMilliseconds([long]($at * 1000)).UtcDateTime }
}

$startedAt = (Get-Date).ToUniversalTime()

# The dashboard shows the average of the last minute: sampling starts once that minute lies wholly inside the load, so
# the dashboard and the log count the same minute of sending.
Write-Step 'Simülatördeki ilk POST bekleniyor'
$firstPost = $null
while (-not $firstPost) {
    $line = Get-ComposeLog 'erp-simulator' 120 | Where-Object { $_.Length -ge 23 -and (Test-PostLine $_) } | Select-Object -First 1
    if ($line) { $firstPost = [datetime]::ParseExact($line.Substring(0, 23), 'yyyy-MM-dd HH:mm:ss.fff', $inv) } else { Start-Sleep -Seconds 2 }
}
$wait = ($firstPost.AddSeconds(60) - (Get-Date).ToUniversalTime()).TotalSeconds
Write-Host ("  İlk POST {0} UTC; ilk örnek panonun 1 dakikası tamamen yük içindeyken, {1:N0} sn sonra" -f $firstPost.ToString('HH:mm:ss'), [math]::Max(0, $wait))
if ($wait -gt 0) { Start-Sleep -Seconds ([int][math]::Ceiling($wait)) }

$rows = @()
for ($n = 0; $n -lt $Samples; $n++) {
    Start-Sleep -Seconds $IntervalSeconds
    $now = (Get-Date).ToUniversalTime()

    # Gönderim hızı: panonun sorgusu ve simülatör logundaki son 60 saniyenin saniye sayımları.
    $rate = Get-PrometheusValue 'sum(rate(erp_send_attempts_total{result!="already_exists"}[1m]))'
    $from = $now.AddSeconds(-60).ToString('yyyy-MM-dd HH:mm:ss', $inv)
    $to = $now.ToString('yyyy-MM-dd HH:mm:ss', $inv)
    $perSecond = @{}
    Get-ComposeLog 'erp-simulator' 75 | Where-Object { $_.Length -ge 19 -and (Test-PostLine $_) } | ForEach-Object {
        $second = $_.Substring(0, 19)
        if ($second -ge $from -and $second -lt $to) { $perSecond[$second] = 1 + [int]$perSecond[$second] }
    }
    $logRate = (($perSecond.Values | Measure-Object -Sum).Sum) / 60.0
    $rateOk = $logRate -gt 0 -and [math]::Abs($rate - $logRate) / $logRate -lt 0.10

    # Kuyruk: Prometheus'taki değer, servisin o toplamadan önceki son okumasıyla birebir aynı mı.
    $queued = Get-PrometheusSample 'outbox_queued'
    $oldest = Get-PrometheusSample 'outbox_oldest_wait_seconds'
    $summary = (Get-Api '/api/v1/invoices/summary').Json
    $reading = Get-ComposeLog 'invoice-service' 40 | Where-Object { $_ -match 'Metrics read from the database queued=(\d+) oldestQueuedSeconds=(\S+)' } |
        ForEach-Object {
            $null = $_ -match 'Metrics read from the database queued=(\d+) oldestQueuedSeconds=(\S+)'
            [pscustomobject]@{
                At = [datetime]::ParseExact($_.Substring(0, 23), 'yyyy-MM-dd HH:mm:ss.fff', $inv)
                Queued = [double]$Matches[1]
                Oldest = [double]$(if ($Matches[2] -eq '-') { 0 } else { $Matches[2] })
            }
        } | Where-Object { $queued -and $_.At -le $queued.At.AddSeconds(1) } | Select-Object -Last 2
    # The reading is logged a few ms after it is stored: a scrape in between already has the newer one.
    $reading = @($reading | Where-Object { $queued.Value -eq $_.Queued -and $oldest.Value -eq $_.Oldest }) + @($reading | Select-Object -Last 1) |
        Select-Object -First 1
    $queueOk = $reading -and $queued.Value -eq $reading.Queued -and $oldest.Value -eq $reading.Oldest

    $rows += [pscustomobject]@{
        Saat = $now.ToString('HH:mm:ss'); 'Pano gönderim/sn' = [math]::Round($rate, 2); 'Log saniye ort.' = [math]::Round($logRate, 2)
        'Log en çok/sn' = ($perSecond.Values | Measure-Object -Maximum).Maximum
        'Pano kuyruk' = $queued.Value; 'Okuma kuyruk' = $reading.Queued
        'Pano en eski sn' = $oldest.Value; 'Okuma en eski sn' = $reading.Oldest
        'Okuma anı' = $(if ($reading) { $reading.At.ToString('HH:mm:ss') }); 'Özet API kuyruk (şimdi)' = $summary.queuedCount
        Sonuç = $(if ($rateOk -and $queueOk) { 'tutarlı' } else { "FARKLI ($(@(if (-not $rateOk) { 'hız' }; if (-not $queueOk) { 'kuyruk' }) -join ', '))" })
    }
    $rows[-1] | Format-Table -AutoSize -HideTableHeaders:($rows.Count -gt 1) | Out-String -Width 250 | ForEach-Object { $_.TrimEnd() } | Write-Host
}

# Kanıt: simülatörün bu süredeki logu ve saniye başına POST tablosu.
$seconds = [int]((Get-Date).ToUniversalTime() - $startedAt).TotalSeconds + 60
$simLog = Get-ComposeLog 'erp-simulator' $seconds
$simLog | Set-Content (Join-Path $OutputDir 'gun11-yuk-simulator.log') -Encoding UTF8
@('saniye_utc,post') + @($simLog | Where-Object { $_.Length -ge 19 -and (Test-PostLine $_) } | Group-Object { $_.Substring(0, 19) } |
    Sort-Object Name | ForEach-Object { "$($_.Name),$($_.Count)" }) | Set-Content (Join-Path $OutputDir 'gun11-yuk-saniye.csv') -Encoding UTF8
$rows | Format-Table -AutoSize | Out-String -Width 250 | Set-Content (Join-Path $OutputDir 'gun11-yuk-pano.txt') -Encoding UTF8

$bad = @($rows | Where-Object { $_.Sonuç -ne 'tutarlı' }).Count
Write-Result ($bad -eq 0) "$($rows.Count - $bad) / $($rows.Count) örnekte pano = simülatörün saniye sayımları ve servisin okuması (tablolar: manual-tests\output\gun11-yuk-pano.txt, gun11-yuk-saniye.csv)"
