# Kontrol listesi 2: Fatura Servisi durdurulunca MetrikToplanamiyor alarmı tetikleniyor, servis açılınca çözülüyor.
#   .\manual-tests\gun12\2-alarm-metrik.ps1
#   .\manual-tests\gun12\2-alarm-metrik.ps1 -Service erp-simulator     (aynı alarm simülatör için)
# Koşul: servis docker compose stop ile durdurulur. Collector servisin metriklerini 15 sn sonra sunmayı bırakır, alarm
# bundan 1 dakika sonra tetiklenir. Çözülme: servis başlatılır, ilk gönderimde metrikleri yeniden görünür.
param([ValidateSet('invoice-service', 'erp-simulator')][string]$Service = 'invoice-service')

. "$PSScriptRoot\_common.ps1"

Write-Title "Alarm: $Service metrikleri toplanamıyor"
Show-AlertRule 'MetrikToplanamiyor'
$since = Get-UtcStamp

Write-Step "Prometheus'ta $Service metrikleri (durdurmadan önce)"
$query = 'target_info{job="' + $Service + '"}'
Write-Host "  ${query}: $(@(Get-Prometheus $query).Count) seri"

Write-Step "$Service durduruluyor"
Invoke-Compose @('stop', $Service)
$stoppedAt = Get-Date
Write-Host "  Durduruldu: $((Get-UtcStamp)) UTC"

$passed = Test-AlertCycle 'MetrikToplanamiyor' $since -FireTimeoutSeconds 240 -ResolveTimeoutSeconds 180 -Resolve {
    Write-Host ("  Durdurmadan tetiklenmeye: {0}" -f (Format-Duration ((Get-Date) - $stoppedAt).TotalSeconds))
    Invoke-Compose @('start', $Service)
    Wait-Health $(if ($Service -eq 'invoice-service') { $ServiceUrl } else { $SimulatorUrl })
    Write-Host "  $Service açıldı: $((Get-UtcStamp)) UTC"
}

# Yalnız bu servisin, bu koşuda başlamış alarmı: alıcının logunda önceki koşulardan kalan çözüldü bildirimleri (başlangıcı
# $since'ten önce) ve öbür servisin satırları dosyaya girmez.
$lines = @(Get-ReceiverLines $since | Where-Object {
    $_ -match 'alertname=MetrikToplanamiyor startsAt=(\S+)' -and $Matches[1].Replace('T', ' ').Substring(0, 19) -ge $since -and
    $_ -match [regex]::Escape("summary=`"$Service servisinin") })
$lines | Set-Content (Join-Path $OutputDir "gun12-2-alarm-metrik-$Service.txt") -Encoding UTF8
$named = @($lines | Where-Object { $_ -match 'status=firing' }).Count -ge 1 -and
    @($lines | Where-Object { $_ -match 'status=resolved' }).Count -ge 1
Write-Result ($passed -and $named) "Alarm $Service için tetiklendi ve çözüldü bildirimi geldi (alıcının logu)"
Write-Host "  Alıcının satırları: manual-tests\output\gun12-2-alarm-metrik-$Service.txt" -ForegroundColor DarkGray
