# Simülatörün hız sınırı 429 sayacı (erp_simulator_rate_limited_total). Servis saniyede en fazla 18 gönderdiği için normal
# çalışmada sınıra (saniyede 20) takılınmaz; sayaç ancak simülatöre doğrudan istekle sınanır.
#   .\manual-tests\gun11\11-hiz-siniri-429.ps1
# Simülatöre aynı anda $Count istek gönderilir. Gövde bilerek geçersizdir: hız sınırı gövde kontrolünden önce uygulanır, sınırın
# içindeki istekler 400 alır ve hiçbir kayıt oluşmaz (mutabakatta "Serviste Yok" bulgusu çıkmasın diye).
param([int]$Count = 30)

. "$PSScriptRoot\_common.ps1"
Add-Type -AssemblyName System.Net.Http

Write-Title 'Simülatörün hız sınırı 429 sayacı'

function Get-RateLimitedCount {
    $line = (Invoke-WebRequest "$SimulatorUrl/metrics" -UseBasicParsing -TimeoutSec 10).Content -split "`n" |
        Where-Object { $_ -match '^erp_simulator_rate_limited_total' } | Select-Object -First 1
    [double](($line -split ' ')[-1])
}

Start-Sleep -Seconds 2
$before = Get-RateLimitedCount
$since = Get-UtcStamp
$client = New-Object System.Net.Http.HttpClient
$requests = 1..$Count | ForEach-Object {
    $body = New-Object System.Net.Http.ByteArrayContent (, [Text.Encoding]::UTF8.GetBytes('{"invoiceNumber":"GUN11-429-' + $_ + '"}'))
    $body.Headers.ContentType = 'application/json'
    $client.PostAsync("$SimulatorUrl/api/v1/invoices", $body)
}
[System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$requests)
$codes = $requests | ForEach-Object { [int]$_.Result.StatusCode }
Start-Sleep -Seconds 7

$after = Get-RateLimitedCount
$prometheus = Get-PrometheusValue 'sum(erp_simulator_rate_limited_total)'
Push-Location $RepoRoot
try { $logLines = @(& docker compose logs erp-simulator --since "$($since.Replace(' ', 'T'))Z" --no-log-prefix 2>$null | Where-Object { "$_" -match 'reason=rateLimited' }) }
finally { Pop-Location }
$rejected = @($codes | Where-Object { $_ -eq 429 }).Count

Write-Host ("  HTTP cevapları: {0}" -f (($codes | Group-Object | Sort-Object Name | ForEach-Object { "$($_.Name) x $($_.Count)" }) -join ', '))
Write-Host "  Sayaç (/metrics): $before -> $after; Prometheus: $prometheus; simülatör logunda reason=rateLimited: $($logLines.Count)"
Write-Result ($rejected -gt 0 -and ($after - $before) -eq $rejected -and $logLines.Count -eq $rejected) "$rejected tane 429; sayaç artışı, log ve Prometheus aynı"
