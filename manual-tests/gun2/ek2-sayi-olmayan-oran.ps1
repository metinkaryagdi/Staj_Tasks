# Gün 2 - Ek test 2 (QA bulgusu 2'nin düzeltmesi): oranların toplamı tam 100 değilse simülatör açılmamalı.
# "NaN" ve "Infinity" ayar dosyasından/ortam değişkeninden sayı olarak okunuyor; NaN ile her karşılaştırma false
# olduğu için düzeltmeden önce Success=NaN iken simülatör açılıyordu (log: total=NaN).
# Her durumda simülatör yeniden oluşturulur; açılmaması gerekenlerde container "exited" olmalı ve hata mesajı
# gelen toplamı yazmalı. Toplamı 100 olanlar açılmalı.
. "$PSScriptRoot\_common.ps1"

Write-Title 'Ek 2) Sayı olmayan / toplamı 100 olmayan oranlar -> simülatör açılmaz'

$cases = @(
    @{ Name = 'Success=NaN';               Env = @{ Simulator__Rates__Success = 'NaN' };                                       Start = $false; Total = 'NaN' }
    @{ Name = 'Success=Infinity';          Env = @{ Simulator__Rates__Success = 'Infinity' };                                  Start = $false; Total = 'Infinity' }
    @{ Name = 'Busy=-Infinity';            Env = @{ Simulator__Rates__Busy = '-Infinity' };                                    Start = $false; Total = '-Infinity' }
    @{ Name = 'Busy=100 (toplam 185)';     Env = @{ Simulator__Rates__Busy = '100' };                                          Start = $false; Total = '185' }
    @{ Name = 'LateResponse=9 (toplam 99)'; Env = @{ Simulator__Rates__LateResponse = '9' };                                   Start = $false; Total = '99' }
    @{ Name = 'Success=59.5 + LateResponse=10.5 (toplam 100)'; Env = @{ Simulator__Rates__Success = '59.5'; Simulator__Rates__LateResponse = '10.5' }; Start = $true; Total = '100' }
)

$allPassed = $true
foreach ($case in $cases) {
    Write-Step $case.Name
    Clear-SimulatorEnv
    foreach ($key in $case.Env.Keys) { Set-Item "Env:$key" $case.Env[$key] }
    try { Invoke-Compose @('up', '-d', '--force-recreate', 'erp-simulator') }
    finally { Clear-SimulatorEnv }

    $state = ''
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        Push-Location $RepoRoot
        try { $state = (& docker compose ps -a erp-simulator --format '{{.State}}' | Out-String).Trim() }
        finally { Pop-Location }
        if ($state -eq 'exited') { break }
        $line = Get-SimulatorLog | Where-Object { $_ -match 'Simulator settings:' } | Select-Object -Last 1
        if ($line) { break }
    }

    if ($case.Start) {
        $line = Get-SimulatorLog | Where-Object { $_ -match 'Simulator settings:' } | Select-Object -Last 1
        $total = if ($line -match '\(total=([^)]+)\)') { $Matches[1] } else { 'yok' }
        Write-Host "  Container: $state"
        Write-Host "  Log: $($line -replace '^.*Simulator settings:', 'Simulator settings:')"
        $ok = $state -eq 'running' -and $total -eq $case.Total
        $expected = "açılır, total=$($case.Total)"
    }
    else {
        $line = Get-SimulatorLog | Where-Object { $_ -match 'must add up to exactly 100' } | Select-Object -Last 1
        $total = if ($line -match 'must add up to exactly 100 \(was ([^:]+):') { $Matches[1] } else { 'yok' }
        Write-Host "  Container: $state"
        Write-Host "  Log: $($line -replace '^.*OptionsValidationException: ', '')"
        $ok = $state -eq 'exited' -and $total -eq $case.Total
        $expected = "açılmaz, mesajdaki toplam $($case.Total)"
    }
    Write-DbVerdict $expected "container $state, toplam $total" $ok | Out-Null
    $allPassed = $allPassed -and $ok
}

Write-Result $allPassed "$($cases.Count) durumun hepsi beklendiği gibi"

Restart-Simulator
