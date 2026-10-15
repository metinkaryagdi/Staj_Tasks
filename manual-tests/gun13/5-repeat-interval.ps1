# Kontrol listesi 5: Alertmanager ayarında repeat_interval 1 saat. Hem ayar dosyasına hem de çalışan Alertmanager'ın
# yüklediği ayara (/api/v2/status) bakılır. Alertmanager ayar dosyasını yalnız açılırken okuduğu için önce yeniden başlatılır.
#   .\manual-tests\gun13\5-repeat-interval.ps1
. "$PSScriptRoot\_common.ps1"

$AlertmanagerUrl = 'http://localhost:9093'

Write-Title 'Kontrol listesi 5: Alertmanager repeat_interval'
$file = Join-Path $RepoRoot 'monitoring\alertmanager\alertmanager.yml'
$fileLine = @(Select-String -Path $file -Pattern '^\s*repeat_interval:' | ForEach-Object { $_.Line.Trim() })
Write-Host "  Ayar dosyası: $($fileLine -join '; ')"

Invoke-Compose @('up', '-d', '--force-recreate', 'alertmanager')
$status = $null
for ($i = 0; $i -lt 30 -and -not $status; $i++) {
    try { $status = Invoke-RestMethod "$AlertmanagerUrl/api/v2/status" -TimeoutSec 5 } catch { Start-Sleep -Seconds 1 }
}
if (-not $status) { throw "Alertmanager 30 sn içinde cevap vermedi ($AlertmanagerUrl)." }
$loaded = @($status.config.original -split "`n" | Where-Object { $_ -match '^\s*repeat_interval:' } | ForEach-Object { $_.Trim() })
Write-Host "  Alertmanager'ın yüklediği ayar (/api/v2/status): $($loaded -join '; ')"

$out = Join-Path $OutputDir 'gun13-5-repeat-interval.txt'
@("Ayar dosyası ($file): $($fileLine -join '; ')", "Alertmanager /api/v2/status: $($loaded -join '; ')", '', $status.config.original) |
    Set-Content $out -Encoding UTF8

Write-Result ($fileLine.Count -eq 1 -and $fileLine[0] -eq 'repeat_interval: 1h' -and $loaded.Count -eq 1 -and $loaded[0] -eq 'repeat_interval: 1h') `
    'repeat_interval ayar dosyasında ve çalışan Alertmanager''da 1h (tek route)'
