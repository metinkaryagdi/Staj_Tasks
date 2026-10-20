# Gün 16 script'lerinin ortak yardımcıları. Gün 15'in _common.ps1'ini de yükler (Gün 1-15 yardımcıları dahil).
# Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun15\_common.ps1"

# Kontrol listesi boş veritabanıyla başlar: compose bu güne özel volume'lerle açılır (staj-tasks_*-db-data-gun16-<Name>);
# eski volume'ler silinmez, dokunulmaz.
Use-Gun10Volumes 'gun16'

# Collector'ın karar süresi (decision_wait), saniye; monitoring/otel-collector/config.yaml'dan okunur (Gün 13'ten beri
# sabit yazılan 1800'ün yerine): karar süresi değişince script'ler değişmeden doğru süre beklenir.
function Get-DecisionWaitSeconds {
    $text = Get-Content (Join-Path $RepoRoot 'monitoring\otel-collector\config.yaml') -Raw -Encoding UTF8
    if ($text -notmatch '(?m)^\s+decision_wait:\s*(\d+)(s|m|h)\s*$') { throw 'config.yaml''da decision_wait bulunamadı.' }
    [int]$Matches[1] * @{ s = 1; m = 60; h = 3600 }[$Matches[2]]
}
$DecisionWaitSeconds = Get-DecisionWaitSeconds

# Prometheus'ta bir aralık sorgusu (query_range); her seri için metric ve values (unix saniye, değer).
function Get-PrometheusRange([string]$Query, [DateTimeOffset]$From, [DateTimeOffset]$To, [int]$Step) {
    $url = "$PrometheusUrl/api/v1/query_range?query=" + [Uri]::EscapeDataString($Query) +
        "&start=$($From.ToUnixTimeSeconds())&end=$($To.ToUnixTimeSeconds())&step=$Step"
    $r = Invoke-RestMethod -Uri $url -TimeoutSec 60
    if ($r.status -ne 'success') { throw "Prometheus sorgusu başarısız: $Query" }
    @($r.data.result)
}

# Bir servisin metriklerinin Prometheus'ta kesintisiz görünüp görünmediği: 5 sn'lik her adımda, son 10 sn içinde
# target_info'nun en az bir örneği var mı (Prometheus 5 sn'de bir toplar; metrik Collector'ı servisten 15 sn gönderim
# gelmezse seriyi sunmayı bırakır). Dönen: Steps (adım sayısı), Missing (örneği olmayan adımların zamanları).
function Test-MetricContinuity([string]$Job, [DateTimeOffset]$From, [DateTimeOffset]$To) {
    $rows = @(Get-PrometheusRange "count_over_time(target_info{job=`"$Job`"}[10s])" $From $To 5)
    $seen = @{}
    foreach ($row in $rows) { foreach ($v in $row.values) { if ([double]$v[1] -gt 0) { $seen[[long]$v[0]] = $true } } }
    $missing = @(); $steps = 0
    for ($t = $From.ToUnixTimeSeconds(); $t -le $To.ToUnixTimeSeconds(); $t += 5) {
        $steps++
        if (-not $seen.ContainsKey([long]$t)) { $missing += [DateTimeOffset]::FromUnixTimeSeconds($t) }
    }
    [pscustomobject]@{ Steps = $steps; Missing = $missing }
}

# Bir alarmın aralıktaki durumları (Prometheus'un ALERTS serisi, 15 sn adımla): pending ya da firing görülen ilk ve son an.
# Hiç görülmediyse boş döner.
function Get-AlertStates([string]$Alert, [DateTimeOffset]$From, [DateTimeOffset]$To) {
    foreach ($row in @(Get-PrometheusRange "ALERTS{alertname=`"$Alert`"}" $From $To 15)) {
        $times = @($row.values | ForEach-Object { [long]$_[0] })
        [pscustomobject]@{ State = $row.metric.alertstate; Job = $row.metric.job
            First = [DateTimeOffset]::FromUnixTimeSeconds(($times | Measure-Object -Minimum).Minimum)
            Last = [DateTimeOffset]::FromUnixTimeSeconds(($times | Measure-Object -Maximum).Maximum) }
    }
}
