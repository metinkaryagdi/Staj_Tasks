# Gün 24 script'lerinin ortak yardımcıları. Gün 23'ün _common.ps1'ini yükler (Start-Stack, Invoke-InvoiceSql, Get-SqlScalar,
# Invoke-Reconciliation, Send-Api dahil). Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun23\_common.ps1"

# Çıktılar günün klasörüne yazılır.
$OutputDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'output\gun24'
New-Item -ItemType Directory -Force $OutputDir | Out-Null

# Koşuların yedekleri çıktı klasöründe durur, varsayılan yedek klasörüne karışmaz.
function Use-BackupFolder([string]$Name) {
    $env:INVOICE_BACKUP_DIR = "./manual-tests/output/gun24/$Name"
    $path = Join-Path $OutputDir $Name
    New-Item -ItemType Directory -Force $path | Out-Null
    $path
}

# Mutabakatı başlatır; zamanlanmış çalışma o an kilidi tutuyorsa (409) bitmesini bekleyip yeniden dener.
function Invoke-ReconciliationRetry {
    for ($i = 0; $i -lt 30; $i++) {
        try { return Invoke-Reconciliation }
        catch { if ("$_" -notmatch 'HTTP 409') { throw }; Start-Sleep -Seconds 10 }
    }
    throw 'Mutabakat 5 dakikada başlatılamadı.'
}

# Çalışmanın logdaki sorgu özeti.
function Get-LookupLine([long]$RunId) {
    Push-Location $RepoRoot
    try {
        $line = @(docker compose logs --no-color --since 2h invoice-service 2>&1 | ForEach-Object { "$_" } |
            Where-Object { $_ -match "Reconciliation ERP lookups run=$RunId " }) | Select-Object -Last 1
        if ($line -match 'asked=(\d+) notFound=(\d+) unanswered=(\d+)') {
            [pscustomobject]@{ Asked = [int]$Matches[1]; NotFound = [int]$Matches[2]; Unanswered = [int]$Matches[3] }
        }
    }
    finally { Pop-Location }
}

function Get-RowSet([string]$Text) {
    $set = [Collections.Generic.HashSet[string]]::new()
    foreach ($row in ($Text -split "`r?`n")) { if ($row.Trim()) { [void]$set.Add($row.Trim()) } }
    , $set
}
