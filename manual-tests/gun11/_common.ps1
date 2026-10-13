# Gün 11 script'lerinin ortak yardımcıları. Gün 10'un _common.ps1'ini de yükler (Gün 1-10 yardımcıları dahil).
# Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun10\_common.ps1"

# Alarm koşulları boş veritabanından başlayarak oluşturulur: compose bu kontrol listesine özel volume'lerle açılır
# (staj-tasks_*-db-data-gun11); eski volume'ler silinmez, dokunulmaz.
Use-Gun10Volumes 'gun11'

$PrometheusUrl = 'http://localhost:9090'
$GrafanaUrl = 'http://localhost:3000'
$AlertmanagerUrl = 'http://localhost:9093'

# Prometheus'a anlık sorgu; sonuç satırları (metric, value). Sorgu hata verirse durur.
function Get-Prometheus([string]$Query) {
    $url = "$PrometheusUrl/api/v1/query?query=" + [Uri]::EscapeDataString($Query)
    $r = Invoke-RestMethod -Uri $url -TimeoutSec 10
    if ($r.status -ne 'success') { throw "Prometheus sorgusu başarısız: $Query" }
    @($r.data.result)
}

# Tek değer dönen sorgunun değeri; sonuç yoksa $null.
function Get-PrometheusValue([string]$Query) {
    $rows = @(Get-Prometheus $Query)
    if ($rows.Count -eq 0) { return $null }
    [double]::Parse($rows[0].value[1], [Globalization.CultureInfo]::InvariantCulture)
}

# Prometheus'ta şu an pending ya da firing olan alarmlar (ad, durum, ne zamandan beri).
function Get-ActiveAlerts {
    @((Invoke-RestMethod -Uri "$PrometheusUrl/api/v1/alerts" -TimeoutSec 10).data.alerts |
        ForEach-Object { [pscustomobject]@{ Alarm = $_.labels.alertname; Durum = $_.state; Başlangıç = $_.activeAt } })
}

# alert-receiver'ın logundaki alarm satırları; -Since (UTC, yyyy-MM-dd HH:mm:ss) verilirse o andan sonrakiler.
function Get-ReceiverLines([string]$Since = '') {
    Push-Location $RepoRoot
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $lines = @(& docker compose logs alert-receiver --no-log-prefix 2>$null | ForEach-Object { "$_" } | Where-Object { $_ -match 'Alert status=' }) }
    finally { $ErrorActionPreference = $previous; Pop-Location }
    @($lines | Where-Object { -not $Since -or ($_.Length -ge 19 -and $_.Substring(0, 19) -ge $Since) })
}

function Get-UtcStamp { (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') }

# Alıcının logunda alarmın verilen durumla (firing / resolved) satırı görünene kadar bekler; satırı döner, süre dolarsa $null.
function Wait-ReceiverLine([string]$Alert, [string]$Status, [string]$Since, [int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastNote = Get-Date
    while ((Get-Date) -lt $deadline) {
        $line = Get-ReceiverLines $Since | Where-Object { $_ -match "status=$Status alertname=$Alert " } | Select-Object -First 1
        if ($line) { return $line }
        if (((Get-Date) - $lastNote).TotalSeconds -ge 60) {
            $state = (Get-ActiveAlerts | Where-Object { $_.Alarm -eq $Alert } | Select-Object -First 1).Durum
            Write-Host ("  {0} bekleniyor: {1}, Prometheus'ta alarm {2}" -f (Get-Date -Format 'HH:mm:ss'), $Status, $(if ($state) { $state } else { 'yok' })) -ForegroundColor DarkGray
            $lastNote = Get-Date
        }
        Start-Sleep -Seconds 5
    }
    $null
}

# Alarmın tetiklenme ve çözülme satırlarını bekler, ikisini de yazar; ikisi de geldiyse $true.
function Test-AlertCycle([string]$Alert, [string]$Since, [scriptblock]$Resolve, [int]$FireTimeoutSeconds, [int]$ResolveTimeoutSeconds) {
    Write-Step "Alıcının logunda $Alert tetiklenmesi bekleniyor (en fazla $([int]($FireTimeoutSeconds / 60)) dk)"
    $fired = Wait-ReceiverLine $Alert 'firing' $Since $FireTimeoutSeconds
    if ($fired) { Write-Host "  $fired" } else { Write-Host '  Tetiklenmedi.' -ForegroundColor Red; return $false }

    Write-Step 'Koşul kaldırılıyor'
    $resolvedSince = Get-UtcStamp
    & $Resolve
    Write-Step "Alıcının logunda $Alert çözüldü bildirimi bekleniyor (en fazla $([int]($ResolveTimeoutSeconds / 60)) dk)"
    $resolved = Wait-ReceiverLine $Alert 'resolved' $resolvedSince $ResolveTimeoutSeconds
    if ($resolved) { Write-Host "  $resolved" } else { Write-Host '  Çözüldü bildirimi gelmedi.' -ForegroundColor Red }
    [bool]$resolved
}

# Kurallar dosyasından alarmın ifadesi ve süresi (raporda koşulun eşiğini göstermek için).
function Show-AlertRule([string]$Alert) {
    $rule = (Invoke-RestMethod -Uri "$PrometheusUrl/api/v1/rules" -TimeoutSec 10).data.groups.rules | Where-Object { $_.name -eq $Alert }
    if (-not $rule) { throw "Prometheus'ta $Alert kuralı yok (monitoring/prometheus/alert-rules.yml yüklenmemiş)." }
    Write-Host "  Kural: $($rule.query)  süre: $(if ($rule.duration) { "$($rule.duration) sn" } else { 'yok' })" -ForegroundColor DarkGray
}
