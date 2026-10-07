# Gün 5 (Mutabakat) script'lerinin ortak yardımcıları. Gün 4'ün gun4\_common.ps1'ini de yükler
# (Gün 1-3 yardımcıları dahil). Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun4\_common.ps1"

$Service2Url = 'http://localhost:5091'

# docker-compose.yml'in Fatura Servisi'ne aktardığı mutabakat ayarları.
$ServiceEnvKeys = @('Reconciliation__IntervalMinutes', 'Reconciliation__LookbackHours',
                    'Reconciliation__StuckAfterMinutes', 'Reconciliation__UnknownEventAfterMinutes',
                    'Reconciliation__NoDecisionAfterMinutes',
                    'Reconciliation__NotFoundRecheckHours')

function Clear-ServiceEnv { foreach ($key in $ServiceEnvKeys) { Remove-Item "Env:$key" -ErrorAction SilentlyContinue } }

function Wait-Health([string]$Url) {
    for ($i = 0; $i -lt 90; $i++) {
        try { if ($script:Http.GetAsync("$Url/health").GetAwaiter().GetResult().IsSuccessStatusCode) { return } } catch { }
        Start-Sleep -Seconds 1
    }
    throw "$Url 90 sn içinde ayağa kalkmadı."
}

# Fatura Servisi'ni (isteğe bağlı ikinci kopyayla) verilen mutabakat ayarlarıyla yeniden oluşturur.
# Ayar verilmezse appsettings.json değerleri geçerli (60 dk aralık, 24 saat, 2 dk, 60 dk).
function Restart-InvoiceService([hashtable]$Settings = @{}, [switch]$WithSecondCopy) {
    Clear-ServiceEnv
    foreach ($key in $Settings.Keys) { Set-Item "Env:$key" ([string]$Settings[$key]) }
    $what = if ($Settings.Count -eq 0) { 'appsettings.json ayarlarıyla' }
            else { 'şu ayarlarla: ' + (($Settings.Keys | Sort-Object | ForEach-Object { "$($_ -replace 'Reconciliation__', '')=$($Settings[$_])" }) -join ', ') }
    Write-Step "Fatura Servisi $what yeniden başlatılıyor$(if ($WithSecondCopy) { ' (ikinci kopyayla)' })"
    try {
        # --build: ikinci kopyanın kendi imajı var; derlenmezse eski kodla açılır.
        if ($WithSecondCopy) { Invoke-Compose @('--profile', 'iki-kopya', 'up', '-d', '--build', '--force-recreate', 'invoice-service', 'invoice-service-2') }
        else { Invoke-Compose @('up', '-d', '--force-recreate', 'invoice-service') }
    }
    finally { Clear-ServiceEnv }
    Wait-Health $ServiceUrl
    if ($WithSecondCopy) { Wait-Health $Service2Url }
    Write-Host '  Fatura Servisi hazır.' -ForegroundColor DarkGray
}

# --- Mutabakat endpoint'leri ---------------------------------------------------------------------------------------

# POST /api/v1/reconciliation-runs: HTTP kodunu, gövdeyi ve (202 ise) çalışma numarasını döner.
function Start-Reconciliation([string]$Url = $ServiceUrl) {
    $response = $script:Http.PostAsync("$Url/api/v1/reconciliation-runs", $null).GetAwaiter().GetResult()
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    [pscustomobject]@{
        Status = [int]$response.StatusCode; Body = $body
        Location = $(if ($response.Headers.Location) { $response.Headers.Location.ToString() } else { '' })
        RunId  = $(if ($body -match '"id":(\d+)') { [long]$Matches[1] } else { 0 })
    }
}

# GET /api/v1/reconciliation-runs/{id}: { run, findings } ya da $null.
function Get-RunDetail([long]$Id) {
    $response = $script:Http.GetAsync("$ServiceUrl/api/v1/reconciliation-runs/$Id").GetAwaiter().GetResult()
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if ($response.IsSuccessStatusCode) { $body | ConvertFrom-Json } else { $null }
}

# Çalışma Çalışıyor durumundan çıkana kadar bekler; son halini döner.
function Wait-RunDone([long]$Id, [int]$TimeoutSeconds = 180) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $detail = Get-RunDetail $Id
        if ($detail -and $detail.run.status -ne 'Çalışıyor') { return $detail }
        if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw "Çalışma $Id $TimeoutSeconds sn içinde bitmedi." }
        Start-Sleep -Milliseconds 500
    }
}

# Mutabakatı elle başlatır ve bitmesini bekler.
function Invoke-Reconciliation([int]$TimeoutSeconds = 180) {
    $started = Start-Reconciliation
    if ($started.Status -ne 202) { throw "Mutabakat başlamadı: HTTP $($started.Status) $($started.Body)" }
    Wait-RunDone $started.RunId $TimeoutSeconds
}

function Show-Run([long]$RunId) {
    Show-ServiceQuery "SELECT id, status, checked_count, fixed_count, reported_count, error FROM reconciliation_runs WHERE id = $RunId;"
}

function Show-Findings([long]$RunId, [string]$Where = '') {
    Show-ServiceQuery "SELECT id, invoice_number, finding_type, action, details FROM reconciliation_findings WHERE run_id = $RunId $Where ORDER BY id;"
}

# Haberler kapalıyken bir fatura oluşturur ve Gönderildi olmasını bekler; numarasını döner.
function New-SentInvoice {
    $number = @(New-Invoices 1)[0]
    Wait-InvoicesIn @($number) @('Gönderildi') 60 'Gönderildi' | Out-Null
    $number
}
