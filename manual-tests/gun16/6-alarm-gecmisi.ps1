# Bellek sınırı denemesinin (4-bellek-denemesi.ps1) ve durdurma denemesinin (5-durdurma.ps1) aralıklarında bütün alarmların
# geçmişi: Prometheus'ta hangi alarm ne zaman pending / firing oldu (ALERTS, 15 sn adım) ve alarm alıcısına hangi bildirim
# geldi. Durdurma denemesinde veritabanından okunan metriklerin Prometheus'ta olup olmadığı da yazılır. Yalnız okur; aralıklar
# iki denemenin çıktı dosyalarından alınır. Alıcının logu container'da tutulduğu için container yeniden oluşturulmadan
# çalıştırılmalıdır.
#   .\manual-tests\gun16\6-alarm-gecmisi.ps1
param([string]$Name = 'bellek')

. "$PSScriptRoot\_common.ps1"

$out = Join-Path $OutputDir 'gun16-6-alarm-gecmisi.txt'
$report = [Collections.Generic.List[string]]::new()
function Write-Line([string]$Text) { Write-Host $Text; $report.Add($Text) }
function Format-Local([DateTimeOffset]$At) { $At.ToLocalTime().ToString('HH:mm:ss') }
$inv = [Globalization.CultureInfo]::InvariantCulture

# Bir sorgunun aralıktaki serileri, sürekli göründüğü parçalarıyla (15 sn adım; iki adımdan uzun boşluk yeni parça başlatır).
function Get-Segments([string]$Query, [DateTimeOffset]$From, [DateTimeOffset]$To) {
    foreach ($row in @(Get-PrometheusRange $Query $From $To 15)) {
        $times = @($row.values | ForEach-Object { [long]$_[0] })
        $parts = @(); $start = $times[0]; $prev = $times[0]
        foreach ($t in $times | Select-Object -Skip 1) {
            if ($t - $prev -gt 15) { $parts += , @($start, $prev); $start = $t }
            $prev = $t
        }
        $parts += , @($start, $prev)
        [pscustomobject]@{ Metric = $row.metric
            Parts = @($parts | ForEach-Object { '{0}-{1}' -f (Format-Local ([DateTimeOffset]::FromUnixTimeSeconds($_[0]))), (Format-Local ([DateTimeOffset]::FromUnixTimeSeconds($_[1]))) }) }
    }
}

function Write-Alerts([DateTimeOffset]$From, [DateTimeOffset]$To) {
    Write-Line "Prometheus'taki alarmlar (ALERTS, 15 sn adım; yerel saat):"
    $rows = @(Get-Segments 'ALERTS' $From $To | Sort-Object { $_.Metric.alertname }, { $_.Metric.alertstate })
    if (-not $rows.Count) { Write-Line '  yok' }
    foreach ($r in $rows) {
        $job = if ($r.Metric.job) { " ($($r.Metric.job))" } else { '' }
        Write-Line ("  {0} {1}{2}: {3}" -f $r.Metric.alertname, $r.Metric.alertstate, $job, ($r.Parts -join ', '))
    }
    Write-Line 'Alarm alıcısına gelen bildirimler (alıcının logu, UTC):'
    $since = $From.UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss'); $until = $To.UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss')
    $lines = @(Get-ReceiverLines $since | Where-Object { $_.Substring(0, 19) -le $until })
    if (-not $lines.Count) { Write-Line '  yok' }
    foreach ($l in $lines) { Write-Line ('  ' + (($l -replace ' summary=.*$', '') -replace ' warn: AlertReceiver\[0\]', '')) }
}

# 1) Bellek sınırı denemesi: yükün başından ret alarmının çözüldüğü bildirime kadar.
$run = @(Get-Content (Join-Path $OutputDir "gun16-1-$Name.txt") -Encoding UTF8)
$null = ($run | Where-Object { $_ -match 'Koşu: GUN16-\S+-(\d{8})-\d{6}; yük (\d\d:\d\d:\d\d)-' } | Select-Object -First 1)
$day = [datetime]::ParseExact($Matches[1], 'yyyyMMdd', $inv).ToString('yyyy-MM-dd')
$fromA = [DateTimeOffset]::Parse("$($day)T$($Matches[2])Z", $inv)
$null = (Get-Content (Join-Path $OutputDir "gun16-4-$Name.txt") -Encoding UTF8 | Where-Object { $_ -match 'Ret alarmı çözüldü: alıcıya (\d\d:\d\d:\d\d) UTC' } | Select-Object -First 1)
$toA = [DateTimeOffset]::Parse("$($day)T$($Matches[1])Z", $inv).AddSeconds(30)
Write-Title 'Alarm geçmişi'
Write-Line "1) Bellek sınırı denemesi ($Name): $(Format-Local $fromA)-$(Format-Local $toA) (yükün başından ret alarmının çözülmesine)."
Write-Alerts $fromA $toA

# 2) Durdurma denemesi: başlangıcından 1 dakika önce bitişine kadar (yerel saatler çıktı dosyasından).
$stop = @(Get-Content (Join-Path $OutputDir 'gun16-5-durdurma.txt') -Encoding UTF8)
$null = ($stop | Where-Object { $_ -match '^\W*Başlangıç \((\d\d:\d\d:\d\d)\)' } | Select-Object -First 1)
$fromB = [DateTimeOffset]::new([datetime]::ParseExact("$day $($Matches[1])", 'yyyy-MM-dd HH:mm:ss', $inv), [TimeZoneInfo]::Local.GetUtcOffset([datetime]::Now)).AddMinutes(-1)
$null = ($stop | Where-Object { $_ -match '^Bitiş \((\d\d:\d\d:\d\d)\)' } | Select-Object -First 1)
$toB = [DateTimeOffset]::new([datetime]::ParseExact("$day $($Matches[1])", 'yyyy-MM-dd HH:mm:ss', $inv), [TimeZoneInfo]::Local.GetUtcOffset([datetime]::Now))
Write-Line ''
Write-Line "2) Durdurma denemesi: $(Format-Local $fromB)-$(Format-Local $toB) (başlangıcından 1 dakika önce bitişine)."
Write-Alerts $fromB $toB
Write-Line "Prometheus'ta göründüğü aralıklar (15 sn adım; yerel saat):"
foreach ($q in 'max(outbox_queued)', 'max(invoices_stuck)', 'max(reconciliation_last_completed_time_seconds)', 'count(target_info{job="invoice-service"})') {
    $s = @(Get-Segments $q $fromB $toB)
    Write-Line ("  {0}: {1}" -f $q, $(if ($s.Count) { $s[0].Parts -join ', ' } else { 'hiç yok' }))
}

$report | Set-Content $out -Encoding UTF8
Write-Host "  Çıktı: manual-tests\output\gun16-6-alarm-gecmisi.txt" -ForegroundColor DarkGray
