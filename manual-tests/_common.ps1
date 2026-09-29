# manual-tests içindeki bütün script'lerin kullandığı ortak yardımcılar.
# Doğrudan çalıştırılmaz; diğer script'ler bunu ". $PSScriptRoot\_common.ps1" ile yükler.

$RepoRoot = Split-Path $PSScriptRoot -Parent
$BaseUrl  = 'http://localhost:5080'
$OutputDir = Join-Path $PSScriptRoot 'output'

Add-Type -AssemblyName System.Net.Http
$script:Http = New-Object System.Net.Http.HttpClient
$script:Http.Timeout = [TimeSpan]::FromMinutes(2)

# docker-compose.yml'in simülatöre aktardığı ayar değişkenleri.
$SimulatorEnvKeys = @(
    'Simulator__Seed',
    'Simulator__Rates__Success',
    'Simulator__Rates__Busy',
    'Simulator__Rates__ServerError',
    'Simulator__Rates__SaveThenError',
    'Simulator__Rates__LateResponse',
    'Simulator__LateResponseDelaySeconds',
    'Simulator__RetryAfterFormat'
)

function Write-Title([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor Cyan
}

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "> $Text" -ForegroundColor Yellow
}

function Write-Result([bool]$Passed, [string]$Text) {
    Write-Host ''
    if ($Passed) { Write-Host "SONUÇ: GEÇTİ  - $Text" -ForegroundColor Green }
    else         { Write-Host "SONUÇ: KALDI  - $Text" -ForegroundColor Red }
}

function Clear-SimulatorEnv {
    foreach ($key in $SimulatorEnvKeys) { Remove-Item "Env:$key" -ErrorAction SilentlyContinue }
}

# docker compose ilerleme çıktısını stderr'e yazar; PowerShell 5.1 bunu hata sanmasın diye sessizce çalıştırılır.
function Invoke-Compose([string[]]$Arguments) {
    Push-Location $RepoRoot
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & docker compose @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            $output | ForEach-Object { Write-Host $_ -ForegroundColor Red }
            throw "docker compose $($Arguments -join ' ') başarısız oldu."
        }
    }
    finally {
        $ErrorActionPreference = $previous
        Pop-Location
    }
}

# Simülatörü verilen ayarlarla yeniden oluşturur. Ayar verilmezse appsettings.json'daki değerler kullanılır.
# Container yeniden oluştuğu için seed'li dizi en baştan başlar.
function Restart-Simulator([hashtable]$Settings = @{}) {
    Clear-SimulatorEnv
    foreach ($key in $Settings.Keys) { Set-Item "Env:$key" ([string]$Settings[$key]) }

    if ($Settings.Count -eq 0) { Write-Step 'Simülatör appsettings.json ayarlarıyla yeniden başlatılıyor...' }
    else {
        $text = ($Settings.Keys | Sort-Object | ForEach-Object { "$($_ -replace 'Simulator__','' -replace '__',':')=$($Settings[$_])" }) -join ', '
        Write-Step "Simülatör şu ayarlarla yeniden başlatılıyor: $text"
    }

    try { Invoke-Compose @('up', '-d', '--force-recreate', 'erp-simulator') }
    finally { Clear-SimulatorEnv }

    for ($i = 0; $i -lt 60; $i++) {
        try {
            $r = $script:Http.GetAsync("$BaseUrl/health").GetAwaiter().GetResult()
            if ($r.IsSuccessStatusCode) {
                Write-Host '  Simülatör hazır.' -ForegroundColor DarkGray
                Show-SimulatorSettings
                return
            }
        } catch { }
        Start-Sleep -Seconds 1
    }
    throw 'Simülatör 60 saniye içinde ayağa kalkmadı. "docker compose logs erp-simulator" ile bakın.'
}

function Show-SimulatorSettings {
    $line = Get-SimulatorLog | Where-Object { $_ -match 'Simulator settings:' } | Select-Object -Last 1
    if ($line) { Write-Host ('  ' + ($line -replace '^.*Simulator settings:', 'Aktif ayarlar:')) -ForegroundColor DarkGray }
}

function Get-SimulatorLog {
    Push-Location $RepoRoot
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & docker compose logs erp-simulator --no-log-prefix 2>$null }
    finally { $ErrorActionPreference = $previous; Pop-Location }
}

# Her çalıştırmada farklı fatura numarası üretmek için: T1-20260929-153012-
function New-Prefix([string]$Test) { "$Test-$(Get-Date -Format 'yyyyMMdd-HHmmss')-" }

function Send-Invoice([string]$InvoiceNumber) {
    $json = '{"invoiceNumber":"' + $InvoiceNumber + '","customerCode":"C-001","amount":1250.50,"currency":"TRY","invoiceDate":"2026-09-29"}'
    $content = New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')

    $watch = [Diagnostics.Stopwatch]::StartNew()
    $response = $script:Http.PostAsync("$BaseUrl/api/v1/invoices", $content).GetAwaiter().GetResult()
    $watch.Stop()

    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $retryAfter = if ($response.Headers.RetryAfter) { $response.Headers.RetryAfter.ToString() } else { '' }
    $reference = if ($body -match '"erpReference":"([^"]+)"') { $Matches[1] } else { '' }

    [pscustomobject]@{
        Invoice      = $InvoiceNumber
        Status       = [int]$response.StatusCode
        RetryAfter   = $retryAfter
        ErpReference = $reference
        Seconds      = [math]::Round($watch.Elapsed.TotalSeconds, 2)
    }
}

function Get-Invoice([string]$InvoiceNumber) {
    $response = $script:Http.GetAsync("$BaseUrl/api/v1/invoices/$([Uri]::EscapeDataString($InvoiceNumber))").GetAwaiter().GetResult()
    [pscustomobject]@{
        Status = [int]$response.StatusCode
        Body   = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
}

function Write-Response($r) {
    $color = switch ($r.Status) { 202 { 'Green' } 429 { 'Yellow' } default { 'Red' } }
    $extra = @()
    if ($r.ErpReference) { $extra += "erpReference=$($r.ErpReference)" }
    if ($r.RetryAfter)   { $extra += "Retry-After=$($r.RetryAfter)" }
    $extra += "süre=$($r.Seconds)s"
    Write-Host ('  {0,-34} -> {1}  {2}' -f $r.Invoice, $r.Status, ($extra -join '  ')) -ForegroundColor $color
}

# Veritabanında sorgu çalıştırır ve tabloyu ekrana basar.
function Invoke-Sql([string]$Sql) {
    Push-Location $RepoRoot
    try { & docker compose exec -T erp-db psql -U erp -d erp_simulator -c $Sql }
    finally { Pop-Location }
}

# Tek bir sayı döndüren sorgu (count gibi).
function Get-SqlScalar([string]$Sql) {
    Push-Location $RepoRoot
    try { ((& docker compose exec -T erp-db psql -U erp -d erp_simulator -tAc $Sql) | Out-String).Trim() }
    finally { Pop-Location }
}

function Get-DbCount([string]$Prefix) {
    [int](Get-SqlScalar "SELECT count(*) FROM invoices WHERE invoice_number LIKE '$Prefix%';")
}

# Veritabanındaki kayıtları gösterir ve aynı sorguyu db.ps1 içinde elle çalıştırmak için yazdırır.
function Show-DbRows([string]$Prefix) {
    $sql = "SELECT id, invoice_number, erp_reference, behavior, received_at FROM invoices WHERE invoice_number LIKE '$Prefix%' ORDER BY id;"
    Write-Step 'Veritabanındaki kayıtlar:'
    Invoke-Sql $sql
    Write-Host '  Aynı sorguyu elle çalıştırmak için: .\manual-tests\db.ps1 açıp şu satırı yapıştırın:' -ForegroundColor DarkGray
    Write-Host "  $sql" -ForegroundColor DarkGray
}
