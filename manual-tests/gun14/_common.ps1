# Gün 14 script'lerinin ortak yardımcıları. Gün 13'ün _common.ps1'ini de yükler (Gün 1-13 yardımcıları dahil).
# Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun13\_common.ps1"

# Kontrol listesi boş veritabanıyla başlar: compose bu güne özel volume'lerle açılır (staj-tasks_*-db-data-gun14-<Name>);
# eski volume'ler silinmez, dokunulmaz.
Use-Gun10Volumes 'gun14'

# Collector'ın kendi metrikleri (compose ağında otel-collector:8888; Prometheus container'ından okunur). Satırlar
# Prometheus metin biçimindedir.
function Get-CollectorMetrics {
    Push-Location $RepoRoot
    try { @(& docker compose exec -T prometheus wget -qO- http://otel-collector:8888/metrics 2>$null) }
    finally { Pop-Location }
}

# Metrik satırlarında adı ve etiketleri $Pattern'e uyanların değerlerinin toplamı (yoksa 0).
function Get-MetricSum([string[]]$Lines, [string]$Pattern) {
    $sum = 0.0
    foreach ($l in $Lines) {
        if ($l -match "^$Pattern" -and $l -notmatch '^#') {
            $sum += [double]::Parse(($l -split ' ')[-1], [Globalization.CultureInfo]::InvariantCulture)
        }
    }
    $sum
}

function ConvertTo-MiB([string]$Text) {
    if ($Text -notmatch '^([\d.]+)\s*([KMG]i?B|B)') { return 0 }
    $v = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
    switch -regex ($Matches[2]) { '^G' { $v * 1024 } '^M' { $v } '^K' { $v / 1024 } default { $v / 1MB } }
}
