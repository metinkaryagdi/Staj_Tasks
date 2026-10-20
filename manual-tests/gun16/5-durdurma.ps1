# Son soru (hangi bileşen durursa operasyon ekibi haberdar olmaz) ve ret alarmının servisin durmasıyla karışmaması için iki
# kısa durdurma denemesi. Açık yığın üzerinde çalışır; hiçbir container'ı yeniden oluşturmaz, yalnız durdurup başlatır.
#   .\manual-tests\gun16\5-durdurma.ps1 -Name uzun
# -Name: yığının açık olduğu volume'lerin adı (gun16-<Name>); compose başka volume'lerle açılmasın diye.
#
#   A) invoice-service durdurulur: MetrikToplanamiyor (invoice-service) tetiklenmeli, CollectorIzReddediyor tetiklenmemeli.
#      Alarm alıcıya gelince servis başlatılır ve MetrikToplanamiyor'un çözülmesi beklenir.
#   B) invoice-db -DbMinutes dakika durdurulur: servis çalışmaya devam eder; veritabanından okunan metriklerin (kuyruk, takılı
#      fatura, son mutabakat) Prometheus'ta kaybolup kaybolmadığı ve hangi alarmın tetiklendiği gözlenir. Sonra başlatılır.
param([string]$Name = 'uzun', [int]$DbMinutes = 5)

. "$PSScriptRoot\_common.ps1"
Use-Gun10Volumes "gun16-$Name"

$prefix = "gun16-5-durdurma"
$out = Join-Path $OutputDir "$prefix.txt"
$report = [Collections.Generic.List[string]]::new()
function Write-Line([string]$Text) { Write-Host $Text; $report.Add($Text) }
function Format-Local([DateTimeOffset]$At) { $At.ToLocalTime().ToString('HH:mm:ss') }

# Prometheus'ta şu an pending ya da firing olan alarmların kısa listesi.
function Get-AlertList { $a = @(Get-ActiveAlerts | ForEach-Object { "$($_.Alarm) $($_.Durum)" }); if ($a.Count) { $a -join ', ' } else { 'yok' } }

Write-Title 'Durdurma denemeleri'
$open = [int]@(Get-ServiceRows "SELECT count(*) FROM erp_outbox WHERE status = 'Bekliyor';")[0]
Write-Line "Başlangıç ($(Format-Local ([DateTimeOffset]::UtcNow))): kuyrukta $open kayıt; Prometheus'taki alarmlar: $(Get-AlertList)."

try {
    # A) invoice-service
    Write-Step 'A) invoice-service durduruluyor'
    $sinceA = Get-UtcStamp; $fromA = [DateTimeOffset]::UtcNow
    Invoke-Compose @('stop', 'invoice-service')
    $fired = Wait-ReceiverLine 'MetrikToplanamiyor' 'firing' $sinceA 300
    $firedAt = [DateTimeOffset]::UtcNow
    Write-Line ''
    Write-Line "A) invoice-service $(Format-Local $fromA)'te durduruldu."
    if ($fired) { Write-Line ("  MetrikToplanamiyor alıcıya geldi ({0} sonra): {1}" -f (Format-Duration ($firedAt - $fromA).TotalSeconds), ($fired -replace ' summary=.*$', '')) }
    else { Write-Line '  MetrikToplanamiyor 5 dakikada alıcıya gelmedi.' }
    Write-Line "  O andaki alarmlar: $(Get-AlertList)"
    Write-Step 'invoice-service başlatılıyor'
    $startA = Get-UtcStamp; $startedA = [DateTimeOffset]::UtcNow
    Invoke-Compose @('start', 'invoice-service')
    Wait-Health $ServiceUrl
    $resolved = Wait-ReceiverLine 'MetrikToplanamiyor' 'resolved' $startA 300
    if ($resolved) { Write-Line ("  Başlatıldı {0}; MetrikToplanamiyor çözüldü ({1} sonra)." -f (Format-Local $startedA), (Format-Duration ([DateTimeOffset]::UtcNow - $startedA).TotalSeconds)) }
    else { Write-Line "  Başlatıldı $(Format-Local $startedA); MetrikToplanamiyor 5 dakikada çözülmedi." }
    $toA = [DateTimeOffset]::UtcNow
    $ret = @(Get-AlertStates 'CollectorIzReddediyor' $fromA $toA)
    Write-Line "  CollectorIzReddediyor bu sürede: $(if ($ret.Count) { ($ret | ForEach-Object { "$($_.State) $(Format-Local $_.First)-$(Format-Local $_.Last)" }) -join '; ' } else { 'hiç pending ya da firing olmadı' })"

    # B) invoice-db
    Write-Step "B) invoice-db $DbMinutes dakika durduruluyor"
    $sinceB = Get-UtcStamp; $fromB = [DateTimeOffset]::UtcNow
    Invoke-Compose @('stop', 'invoice-db')
    $samples = @()
    while (([DateTimeOffset]::UtcNow - $fromB).TotalMinutes -lt $DbMinutes) {
        Start-Sleep -Seconds 30
        $samples += [pscustomobject]@{ At = [DateTimeOffset]::UtcNow
            Queue = (Get-PrometheusValue 'max(outbox_queued)'); Stuck = (Get-PrometheusValue 'max(invoices_stuck)')
            Service = (Get-PrometheusValue 'count(target_info{job="invoice-service"})'); Alerts = (Get-AlertList) }
        $s = $samples[-1]
        Write-Host ("  {0}: outbox_queued {1}, invoices_stuck {2}, invoice-service target_info {3}; alarmlar: {4}" -f (Format-Local $s.At),
            $(if ($null -eq $s.Queue) { 'yok' } else { $s.Queue }), $(if ($null -eq $s.Stuck) { 'yok' } else { $s.Stuck }),
            $(if ($null -eq $s.Service) { 'yok' } else { $s.Service }), $s.Alerts) -ForegroundColor DarkGray
    }
    $toB = [DateTimeOffset]::UtcNow
    Write-Line ''
    Write-Line "B) invoice-db $(Format-Local $fromB)-$(Format-Local $toB) arasında durduruldu."
    $noQueue = @($samples | Where-Object { $null -eq $_.Queue }).Count
    $noService = @($samples | Where-Object { $null -eq $_.Service }).Count
    Write-Line ("  30 sn'de bir {0} ölçüm: outbox_queued olmayan {1}, invoices_stuck olmayan {2}, invoice-service'in metrikleri olmayan {3}." -f
        $samples.Count, $noQueue, @($samples | Where-Object { $null -eq $_.Stuck }).Count, $noService)
    Write-Line "  Son ölçümdeki alarmlar: $($samples[-1].Alerts)"
    $lines = @(Get-ReceiverLines $sinceB)
    Write-Line "  Alıcıya bu sürede gelen alarm satırı: $($lines.Count)"
    foreach ($l in $lines) { Write-Line ("    " + ($l -replace ' summary=.*$', '')) }
    Push-Location $RepoRoot
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $readErrors = @(& docker compose logs invoice-service --no-log-prefix --since $fromB.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') 2>$null | ForEach-Object { "$_" } | Where-Object { $_ -match 'Metrics could not be read' }).Count }
    finally { $ErrorActionPreference = $previous; Pop-Location }
    Write-Line "  invoice-service logunda 'Metrics could not be read' satırı: $readErrors"
}
finally {
    Write-Step 'invoice-db ve invoice-service açık bırakılıyor'
    Invoke-Compose @('start', 'invoice-db', 'invoice-service')
    Wait-Health $ServiceUrl
    Start-Sleep -Seconds 30
    Write-Line ''
    Write-Line ("Bitiş ({0}): outbox_queued {1}; Prometheus'taki alarmlar: {2}." -f (Format-Local ([DateTimeOffset]::UtcNow)),
        (Get-PrometheusValue 'max(outbox_queued)'), (Get-AlertList))
    $report | Set-Content $out -Encoding UTF8
    Write-Host "  Çıktı: manual-tests\output\$prefix.txt" -ForegroundColor DarkGray
}
