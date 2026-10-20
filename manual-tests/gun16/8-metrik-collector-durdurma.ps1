# Metrik Collector'ı durursa ne olur: açık yığında otel-collector-metrics durdurulur, iki servisin MetrikToplanamiyor alarmının
# birlikte gelmesi beklenir; sonra başlatılır ve alarmların çözülmesi beklenir. Hiçbir container'ı yeniden oluşturmaz.
#   .\manual-tests\gun16\8-metrik-collector-durdurma.ps1 -Name uzun
# -Name: yığının açık olduğu volume'lerin adı (gun16-<Name>).
param([string]$Name = 'uzun')

. "$PSScriptRoot\_common.ps1"
Use-Gun10Volumes "gun16-$Name"

$out = Join-Path $OutputDir 'gun16-8-metrik-collector-durdurma.txt'
$report = [Collections.Generic.List[string]]::new()
function Write-Line([string]$Text) { Write-Host $Text; $report.Add($Text) }
function Format-Local([DateTimeOffset]$At) { $At.ToLocalTime().ToString('HH:mm:ss') }
function Get-AlertList { $a = @(Get-ActiveAlerts | ForEach-Object { "$($_.Alarm) $($_.Durum)" }); if ($a.Count) { $a -join ', ' } else { 'yok' } }

# Alıcının logunda verilen alarmın verilen durumla, verilen servis için satırı gelene kadar bekler; satırı ya da $null döner.
function Wait-JobLine([string]$Status, [string]$Job, [string]$Since, [int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $line = Get-ReceiverLines $Since | Where-Object { $_ -match "status=$Status alertname=MetrikToplanamiyor " -and $_ -match [regex]::Escape("$Job servis") } | Select-Object -First 1
        if ($line) { return $line }
        Start-Sleep -Seconds 5
    }
    $null
}

Write-Title "Metrik Collector'ının durması"
Write-Line "Başlangıç ($(Format-Local ([DateTimeOffset]::UtcNow))): Prometheus'taki alarmlar: $(Get-AlertList)."
try {
    $since = Get-UtcStamp; $from = [DateTimeOffset]::UtcNow
    Invoke-Compose @('stop', 'otel-collector-metrics')
    foreach ($job in 'invoice-service', 'erp-simulator') {
        $line = Wait-JobLine 'firing' $job $since 300
        if ($line) {
            $at = [DateTimeOffset]::Parse($line.Substring(0, 23).Replace(' ', 'T') + 'Z', [Globalization.CultureInfo]::InvariantCulture)
            Write-Line ("  MetrikToplanamiyor ({0}) alıcıya geldi: {1} ({2} sonra)" -f $job, (Format-Local $at), (Format-Duration ($at - $from).TotalSeconds))
        }
        else { Write-Line "  MetrikToplanamiyor ($job) 5 dakikada alıcıya gelmedi." }
    }
    Write-Line "  O andaki alarmlar: $(Get-AlertList)"
}
finally {
    $startStamp = Get-UtcStamp; $started = [DateTimeOffset]::UtcNow
    Invoke-Compose @('start', 'otel-collector-metrics')
    Write-Line "Metrik Collector'ı $(Format-Local $from)'te durduruldu, $(Format-Local $started)'te başlatıldı."
    foreach ($job in 'invoice-service', 'erp-simulator') {
        $line = Wait-JobLine 'resolved' $job $startStamp 300
        Write-Line ("  MetrikToplanamiyor ({0}) çözüldü: {1}" -f $job, $(if ($line) { 'evet' } else { '5 dakikada çözülmedi' }))
    }
    Write-Line "Bitiş ($(Format-Local ([DateTimeOffset]::UtcNow))): Prometheus'taki alarmlar: $(Get-AlertList)."
    $report | Set-Content $out -Encoding UTF8
    Write-Host "  Çıktı: manual-tests\output\gun16-8-metrik-collector-durdurma.txt" -ForegroundColor DarkGray
}
