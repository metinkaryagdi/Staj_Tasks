# 5. madde: Prometheus 5 saniyede bir topladığı halde veritabanına 15 saniyede bir sorgu gittiği loglarla gösterilir.
#   .\manual-tests\gun11\9-veritabani-okuma.ps1
# Fatura Servisi gelen istekleri de loglayacak şekilde (compose.istek-logu.yml) yeniden başlatılır, $Seconds saniye beklenir.
# Logdan: Prometheus'un GET /metrics istekleri ("Request starting ... /metrics") ve veritabanı okumaları ("Metrics read from
# the database"), zamanları ve aralarındaki süre. Okumalar arası en az 15 sn olmalı ("en fazla 15 saniyede bir sorgu").
# Sonunda servis normal ayarlarla yeniden başlatılır.
param([int]$Seconds = 120)

. "$PSScriptRoot\_common.ps1"

function Get-Intervals([string[]]$Lines) {
    $times = @($Lines | ForEach-Object { [datetime]::ParseExact($_.Substring(0, 23), 'yyyy-MM-dd HH:mm:ss.fff', $null) })
    @(for ($i = 1; $i -lt $times.Count; $i++) { [math]::Round(($times[$i] - $times[$i - 1]).TotalSeconds, 1) })
}

Write-Title 'Prometheus 5 sn''de bir toplar, veritabanına 15 sn''de bir sorgu gider'

$composeFiles = $env:COMPOSE_FILE
$env:COMPOSE_FILE = $composeFiles + ';' + (Join-Path $PSScriptRoot 'compose.istek-logu.yml')
try { Restart-InvoiceService }
finally { $env:COMPOSE_FILE = $composeFiles }
$since = Get-UtcStamp
Write-Step "$Seconds sn bekleniyor"
Start-Sleep -Seconds $Seconds

$log = @(Get-ServiceLog | ForEach-Object { "$_" } | Where-Object { $_.Length -ge 23 -and $_.Substring(0, 19) -ge $since })
$scrapes = @($log | Where-Object { $_ -match 'Request starting .* GET .*/metrics' })
$reads = @($log | Where-Object { $_ -match 'Metrics read from the database' })
$scrapeGaps = Get-Intervals $scrapes
$readGaps = Get-Intervals $reads

Write-Step 'GET /metrics (Prometheus), ilk 6 satır'
$scrapes | Select-Object -First 6 | ForEach-Object { Write-Host "  $($_.Substring(0, [math]::Min(140, $_.Length)))" }
Write-Host "  $($scrapes.Count) istek; aralıklar (sn): $($scrapeGaps -join ', ')" -ForegroundColor DarkGray
Write-Step 'Veritabanı okumaları'
$reads | ForEach-Object { Write-Host "  $($_.Substring(0, [math]::Min(170, $_.Length)))" }
Write-Host "  $($reads.Count) okuma; aralıklar (sn): $($readGaps -join ', ')" -ForegroundColor DarkGray

$log | Set-Content (Join-Path $OutputDir 'gun11-veritabani-okuma.log') -Encoding UTF8
Restart-InvoiceService

$scrapeOk = $scrapeGaps.Count -gt 0 -and ($scrapeGaps | Measure-Object -Maximum).Maximum -lt 7.5
$readOk = $readGaps.Count -gt 0 -and ($readGaps | Measure-Object -Minimum).Minimum -ge 15
Write-Result ($scrapeOk -and $readOk) ("{0} toplama (en uzun aralık {1} sn), {2} veritabanı okuması (en kısa aralık {3} sn); log: manual-tests\output\gun11-veritabani-okuma.log" -f
    $scrapes.Count, ($scrapeGaps | Measure-Object -Maximum).Maximum, $reads.Count, ($readGaps | Measure-Object -Minimum).Minimum)
