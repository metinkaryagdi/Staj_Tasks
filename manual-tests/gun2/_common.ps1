# Gün 2 (Fatura Servisi) script'lerinin ortak yardımcıları. Gün 1'in _common.ps1'ini de yükler
# (Restart-Simulator, Write-Title, Invoke-Compose ...). Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\_common.ps1"

$ServiceUrl = 'http://localhost:5090'
$SimulatorUrl = $BaseUrl

# psql çıktısındaki Türkçe karakterler (Gönderildi / Başarısız) Windows PowerShell 5.1'de bozulmasın.
[Console]::OutputEncoding = [Text.Encoding]::UTF8

function Invoke-ServiceSql([string]$Sql) {
    Push-Location $RepoRoot
    try { & docker compose exec -T invoice-db psql -U invoice -d invoice_service -c $Sql }
    finally { Pop-Location }
}

# Satır başına bir kayıt, kolonlar '|' ile ayrılmış (başlık yok).
function Get-ServiceRows([string]$Sql) {
    Push-Location $RepoRoot
    try { @(& docker compose exec -T invoice-db psql -U invoice -d invoice_service -tA -F '|' -c $Sql | Where-Object { $_ }) }
    finally { Pop-Location }
}

function Wait-Service {
    for ($i = 0; $i -lt 60; $i++) {
        try {
            if ($script:Http.GetAsync("$ServiceUrl/health").GetAwaiter().GetResult().IsSuccessStatusCode) { return }
        } catch { }
        Start-Sleep -Seconds 1
    }
    throw 'Fatura Servisi 60 saniye içinde cevap vermedi. "docker compose up -d --build" ile başlatın.'
}

function ConvertTo-ServiceResult($response, $watch) {
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $invoice = $null
    try { $invoice = $body | ConvertFrom-Json } catch { }
    [pscustomobject]@{
        HttpStatus    = [int]$response.StatusCode
        InvoiceNumber = if ($invoice) { $invoice.invoiceNumber } else { '' }
        Status        = if ($invoice) { $invoice.status } else { '' }
        ErpReference  = if ($invoice) { $invoice.erpReference } else { '' }
        LastError     = if ($invoice) { $invoice.lastError } else { '' }
        Attempts      = if ($invoice) { $invoice.sendAttemptCount } else { 0 }
        Seconds       = [math]::Round($watch.Elapsed.TotalSeconds, 2)
        Body          = $body
    }
}

function New-ServiceInvoice {
    $json = '{"customerCode":"C-001","amount":1250.50,"currency":"TRY","invoiceDate":"2026-09-30"}'
    $content = New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $response = $script:Http.PostAsync("$ServiceUrl/api/v1/invoices", $content).GetAwaiter().GetResult()
    $watch.Stop()
    ConvertTo-ServiceResult $response $watch
}

function Send-ServiceResend([string]$InvoiceNumber) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $response = $script:Http.PostAsync("$ServiceUrl/api/v1/invoices/$InvoiceNumber/resend", $null).GetAwaiter().GetResult()
    $watch.Stop()
    ConvertTo-ServiceResult $response $watch
}

function Get-SimulatorInvoice([string]$InvoiceNumber) {
    $response = $script:Http.GetAsync("$SimulatorUrl/api/v1/invoices/$InvoiceNumber").GetAwaiter().GetResult()
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $data = if ([int]$response.StatusCode -eq 200) { $body | ConvertFrom-Json } else { $null }
    [pscustomobject]@{
        HttpStatus  = [int]$response.StatusCode
        RecordCount = if ($data) { [int]$data.recordCount } else { 0 }
        References  = if ($data) { @($data.records | ForEach-Object { $_.erpReference }) } else { @() }
        Body        = $body
    }
}

function Write-ServiceResult($r) {
    $color = if ($r.Status -eq 'Gönderildi') { 'Green' } else { 'Red' }
    $detail = if ($r.Status -eq 'Gönderildi') { "erpReference=$($r.ErpReference)" } else { "lastError=$($r.LastError)" }
    Write-Host ('  {0,-12} -> {1} {2,-10} deneme={3}  süre={4}s  {5}' -f `
        $r.InvoiceNumber, $r.HttpStatus, $r.Status, $r.Attempts, $r.Seconds, $detail) -ForegroundColor $color
}

# Simülatör loglarından "invoice=FTR-... behavior=X" satırlarını okur: her fatura için seçilen davranışlar (sırayla).
function Get-SimulatorBehaviors {
    $map = @{}
    foreach ($line in Get-SimulatorLog) {
        if ($line -match 'ERP request #(\d+) invoice=(\S+) behavior=(\w+)') {
            if (-not $map.ContainsKey($Matches[2])) { $map[$Matches[2]] = @() }
            $map[$Matches[2]] += $Matches[3]
        }
    }
    $map
}

# ---------------------------------------------------------------------------
# Karşılaştırma: servisteki her fatura simülatörün GET endpoint'iyle sorgulanır.
# -From / -To verilirse yalnızca o aralıktaki faturalar (fatura numarasına göre, dahil).
# ---------------------------------------------------------------------------
function Compare-Invoices([string]$From, [string]$To, [switch]$Quiet) {
    $where = @()
    if ($From) { $where += "invoice_number >= '$From'" }
    if ($To)   { $where += "invoice_number <= '$To'" }
    $whereSql = if ($where) { 'WHERE ' + ($where -join ' AND ') } else { '' }

    $rows = @(Get-ServiceRows ("SELECT invoice_number, status, coalesce(erp_reference, ''), send_attempt_count " +
        "FROM invoices $whereSql ORDER BY invoice_number;"))

    $result = [ordered]@{
        Total = 0; SentFound = 0; SentMissing = 0; FailedMissing = 0; FailedFound = 0
        MultipleRecords = 0; ReferenceMatches = 0; SimulatorRecords = 0; Details = @()
    }
    foreach ($row in $rows) {
        $number, $status, $reference, $attempts = $row -split '\|'
        $sim = Get-SimulatorInvoice $number
        $found = $sim.HttpStatus -eq 200
        $result.Total++
        $result.SimulatorRecords += $sim.RecordCount
        if ($sim.RecordCount -gt 1) { $result.MultipleRecords++ }

        if ($status -eq 'Gönderildi') {
            if ($found) { $result.SentFound++ } else { $result.SentMissing++ }
            if ($found -and $sim.References -contains $reference) { $result.ReferenceMatches++ }
        }
        elseif ($found) { $result.FailedFound++ }
        else { $result.FailedMissing++ }

        $result.Details += [pscustomobject]@{
            Invoice = $number; Status = $status; Attempts = [int]$attempts; ServiceReference = $reference
            SimulatorRecords = $sim.RecordCount; SimulatorReferences = ($sim.References -join ',')
        }
    }

    if (-not $Quiet) { Write-Comparison ([pscustomobject]$result) }
    [pscustomobject]$result
}

function Write-Comparison($c) {
    Write-Host ''
    Write-Host ('  {0,-46} {1,12}' -f 'Durum', 'Fatura sayısı') -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 60)) -ForegroundColor Cyan
    Write-Host ('  {0,-46} {1,12}' -f 'Serviste Gönderildi, simülatörde var', $c.SentFound)
    Write-Host ('  {0,-46} {1,12}' -f 'Serviste Başarısız, simülatörde yok', $c.FailedMissing)
    Write-Host ('  {0,-46} {1,12}' -f 'Serviste Başarısız, simülatörde var', $c.FailedFound)
    Write-Host ('  {0,-46} {1,12}' -f 'Serviste Gönderildi, simülatörde yok', $c.SentMissing)
    Write-Host ('  {0,-46} {1,12}' -f 'Simülatörde birden fazla kaydı olan', $c.MultipleRecords)
    Write-Host ('  ' + ('-' * 60)) -ForegroundColor Cyan
    Write-Host ('  {0,-46} {1,12}' -f 'Toplam fatura (serviste)', $c.Total)
    Write-Host ('  {0,-46} {1,12}' -f 'Toplam kayıt (simülatörde)', $c.SimulatorRecords)
    Write-Host ('  {0,-46} {1,12}' -f 'erp_reference simülatördekiyle aynı', "$($c.ReferenceMatches)/$($c.SentFound + $c.SentMissing)")
}

# Bir script'in oluşturduğu fatura aralığını sonraki script'e aktarmak için (3 -> 4).
function Save-Range([string]$Name, [string]$From, [string]$To) {
    New-Item -ItemType Directory -Force $OutputDir | Out-Null
    @{ From = $From; To = $To } | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $OutputDir "$Name.json")
}

function Read-Range([string]$Name) {
    $path = Join-Path $OutputDir "$Name.json"
    if (-not (Test-Path $path)) { return $null }
    Get-Content $path -Raw | ConvertFrom-Json
}
