# Gün 2 - Madde 1: Oranların toplamı 100 değilken simülatör açılmıyor ve hata mesajında gelen toplam yazıyor.
# Yalnızca Busy=100 verilir, diğer oranlar appsettings.json'dan gelir: 60 + 100 + 10 + 5 + 10 = 185.
. "$PSScriptRoot\_common.ps1"

Write-Title '1) Oran toplamı 100 değil (Busy=100, diğerleri varsayılan) -> simülatör açılmaz, toplam 185 yazar'

Clear-SimulatorEnv
$env:Simulator__Rates__Busy = '100'
Write-Step 'Simülatör yalnızca Simulator__Rates__Busy=100 ile yeniden oluşturuluyor'
try { Invoke-Compose @('up', '-d', '--force-recreate', 'erp-simulator') }
finally { Clear-SimulatorEnv }

$state = ''
for ($i = 0; $i -lt 30; $i++) {
    Push-Location $RepoRoot
    try { $state = (& docker compose ps -a erp-simulator --format '{{.State}} {{.Status}}' | Out-String).Trim() }
    finally { Pop-Location }
    if ($state -like 'exited*') { break }
    Start-Sleep -Seconds 1
}
Write-Host "  Container durumu: $state"

$healthy = $false
try { $healthy = $script:Http.GetAsync("$BaseUrl/health").GetAwaiter().GetResult().IsSuccessStatusCode } catch { }
Write-Host "  GET /health: $(if ($healthy) { 'cevap verdi' } else { 'cevap yok' })"

$errorLine = Get-SimulatorLog | Where-Object { $_ -match 'must add up to exactly 100' } | Select-Object -First 1
Write-Host "  Log: $errorLine"

$total = if ($errorLine -match '\(was ([0-9.]+):') { $Matches[1] } else { 'yok' }
Write-Result ($state -like 'exited*' -and -not $healthy -and $total -eq '185') `
    "container: $state, hata mesajındaki toplam: $total"

Restart-Simulator
