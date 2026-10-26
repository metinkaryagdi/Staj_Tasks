# Kontrol listesi 4: repodaki bütün testler art arda 10 kez — Fatura Servisi çözümü (birim + Postgres ve Keycloak'lı
# entegrasyon testleri), ERP Simülatörü'nün testleri ve operasyon ekranının testleri (vitest). Her turda her takımın sonucu
# ve süresi yazılır. Rapor manual-tests/output/gun19-4-on-tekrar.txt. Docker açık olmalı; ~40 dk.
#   .\manual-tests\gun19\4-on-tekrar.ps1
param([int]$Tur = 10)
. "$PSScriptRoot\_common.ps1"

# dotnet test'in özet satırı dilden bağımsız okunsun diye İngilizce.
$env:DOTNET_CLI_UI_LANGUAGE = 'en'

function Invoke-Suite([string]$Name, [scriptblock]$Command, [string]$Pattern) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $output = & $Command 2>&1 | ForEach-Object { "$_" }
    $watch.Stop()
    $summary = @($output | Where-Object { $_ -match $Pattern })
    [pscustomobject]@{
        Name = $Name; ExitCode = $LASTEXITCODE; Seconds = $watch.Elapsed.TotalSeconds; Summary = $summary
    }
}

New-Report 'gun19-4-on-tekrar'
Write-Title "Kontrol listesi 4) Bütün testler art arda $Tur kez"
$allPassed = $true
for ($i = 1; $i -le $Tur; $i++) {
    Write-Line ''
    Write-Line "Tur $i ($(Get-Date -Format 'HH:mm:ss'))"
    $suites = @(
        (Invoke-Suite 'Fatura Servisi' { dotnet test (Join-Path $RepoRoot 'invoice-service\InvoiceService.slnx') } '(Passed|Failed)!'),
        (Invoke-Suite 'ERP Simülatörü' { dotnet test (Join-Path $RepoRoot 'erp-simulator\ErpSimulator.slnx') } '(Passed|Failed)!'),
        (Invoke-Suite 'Operasyon ekranı' { Push-Location (Join-Path $RepoRoot 'operations-ui'); try { npm test } finally { Pop-Location } } '^\s*Tests\s')
    )
    foreach ($s in $suites) {
        $ok = $s.ExitCode -eq 0
        if (-not $ok) { $allPassed = $false }
        Write-Line ("  [{0}] {1} ({2:N0} sn)" -f $(if ($ok) { 'GEÇTİ' } else { 'KIRILDI' }), $s.Name, $s.Seconds)
        foreach ($line in $s.Summary) { Write-Line "      $($line.Trim() -replace '\s{2,}', ' ')" }
    }
}
Write-Line ''
Save-Report
Write-Result $allPassed "$Tur turun hepsinde üç takımın bütün testleri geçti."
