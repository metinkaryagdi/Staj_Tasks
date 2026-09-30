# manual-tests içindeki (gun1 ve gun2) bütün script'lerin kullandığı ortak yardımcılar.
# Doğrudan çalıştırılmaz; diğer script'ler bunu ". $PSScriptRoot\_common.ps1" ile yükler.

$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$BaseUrl  = 'http://localhost:5080'
$OutputDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'output'

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

# ---------------------------------------------------------------------------
# Veritabanı kontrolleri. Her test script'i bunları kendi çıktısının hemen ardından çağırır.
# Her biri başlık, SQL, veritabanından gelen tablo ve beklenen/gelen karşılaştırmasını basar,
# sonuç olarak $true/$false döner.
# ---------------------------------------------------------------------------

function Write-DbHeader([string]$Title, [string]$Subject) {
    Write-Host ''
    Write-Host ('-' * 70) -ForegroundColor Magenta
    Write-Host " VERİTABANI KONTROLÜ - $Title" -ForegroundColor Magenta
    Write-Host ('-' * 70) -ForegroundColor Magenta
    if ($Subject) { Write-Host " $Subject" -ForegroundColor Magenta }
}

function Show-Query([string]$Sql) {
    Write-Host ''
    Write-Host "SQL: $Sql" -ForegroundColor DarkGray
    Invoke-Sql $Sql | Out-Host
}

function Write-DbVerdict([string]$Expected, [string]$Actual, [bool]$Passed) {
    Write-Host "  Beklenen: $Expected"
    if ($Passed) { Write-Host "  Gelen   : $Actual  -> GEÇTİ" -ForegroundColor Green }
    else         { Write-Host "  Gelen   : $Actual  -> KALDI" -ForegroundColor Red }
    $Passed
}

function Write-ManualQuery([string]$Sql) {
    Write-Host "  Kayıtları tek tek görmek için: .\manual-tests\gun1\db.ps1 -Sql `"$Sql`"" -ForegroundColor DarkGray
}

# Test 1, 3, 4: öneki taşıyan $Count kaydın hepsi veritabanında, hepsi $Behavior ve hepsinin referansı farklı olmalı.
function Test-DbAllSaved([string]$Title, [string]$Prefix, [int]$Count, [string]$Behavior, [switch]$ShowRows) {
    Write-DbHeader $Title "Fatura öneki: $Prefix"
    $where = "invoice_number LIKE '$Prefix%'"
    $listSql = "SELECT id, invoice_number, erp_reference, behavior, received_at FROM invoices WHERE $where ORDER BY id;"

    if ($ShowRows) { Show-Query $listSql }
    else {
        Show-Query ("SELECT behavior, count(*) AS kayit, count(DISTINCT erp_reference) AS farkli_referans, " +
            "min(erp_reference) AS ilk_referans, max(erp_reference) AS son_referans FROM invoices WHERE $where GROUP BY behavior;")
        Write-ManualQuery $listSql
    }

    $total    = [int](Get-SqlScalar "SELECT count(*) FROM invoices WHERE $where;")
    $matching = [int](Get-SqlScalar "SELECT count(*) FROM invoices WHERE $where AND behavior = '$Behavior';")
    $distinct = [int](Get-SqlScalar "SELECT count(DISTINCT erp_reference) FROM invoices WHERE $where;")

    Write-Host ''
    Write-DbVerdict "$Count kayıt, hepsi $Behavior, $Count farklı ERP referansı" `
        "$total kayıt, $matching tanesi $Behavior, $distinct farklı ERP referansı" `
        ($total -eq $Count -and $matching -eq $Count -and $distinct -eq $Count)
}

# Test 2: öneki taşıyan hiçbir kayıt olmamalı.
function Test-DbNoneSaved([string]$Title, [string]$Prefix) {
    Write-DbHeader $Title "Fatura öneki: $Prefix"
    Show-Query "SELECT count(*) AS kayit FROM invoices WHERE invoice_number LIKE '$Prefix%';"
    $total = [int](Get-SqlScalar "SELECT count(*) FROM invoices WHERE invoice_number LIKE '$Prefix%';")

    Write-Host ''
    Write-DbVerdict '0 kayıt' "$total kayıt" ($total -eq 0)
}

# Test 5: aynı fatura numarasıyla iki kayıt, iki farklı ERP referansı.
function Test-DbDuplicate([string]$Title, [string]$InvoiceNumber) {
    Write-DbHeader $Title "Fatura numarası: $InvoiceNumber"
    $where = "invoice_number = '$InvoiceNumber'"
    Show-Query "SELECT id, invoice_number, erp_reference, behavior, received_at FROM invoices WHERE $where ORDER BY id;"

    $total    = [int](Get-SqlScalar "SELECT count(*) FROM invoices WHERE $where;")
    $distinct = [int](Get-SqlScalar "SELECT count(DISTINCT erp_reference) FROM invoices WHERE $where;")

    Write-Host ''
    Write-DbVerdict '2 kayıt, 2 farklı ERP referansı' "$total kayıt, $distinct farklı ERP referansı" `
        ($total -eq 2 -and $distinct -eq 2)
}

# Test 6: A ve B çalıştırmalarında aynı istek numaraları aynı davranışla kaydedilmiş olmalı.
# Busy ve ServerError kaydedilmediği için veritabanında yalnızca Success, LateResponse ve SaveThenError görünür;
# davranış dizisinin tamamı loglardan karşılaştırılır.
function Test-DbSeed([string]$Title, [string]$Base) {
    Write-DbHeader $Title "Fatura öneki: ${Base}A- ve ${Base}B-"
    Show-Query ("SELECT split_part(invoice_number, '-', 4) AS calistirma, behavior, count(*) AS kayit " +
        "FROM invoices WHERE invoice_number LIKE '$Base%' GROUP BY 1, 2 ORDER BY 2, 1;")

    $sequence = "SELECT coalesce(string_agg(split_part(invoice_number, '-', 5) || '=' || behavior, ' ' " +
        "ORDER BY split_part(invoice_number, '-', 5)::int), '') FROM invoices WHERE invoice_number LIKE '{0}%';"
    $a = Get-SqlScalar ($sequence -f "${Base}A-")
    $b = Get-SqlScalar ($sequence -f "${Base}B-")
    $countA = if ($a) { @($a -split ' ').Count } else { 0 }
    $countB = if ($b) { @($b -split ' ').Count } else { 0 }

    Write-Host ''
    Write-DbVerdict 'A ve B''de aynı istek numaraları, aynı davranışla kayıtlı' `
        "A: $countA kayıt, B: $countB kayıt, istek numarası + davranış eşleşmesi: $(if ($a -and $a -eq $b) { 'birebir aynı' } else { 'FARKLI' })" `
        ([bool]$a -and $a -eq $b)
}

# Test 7: sorgulanan fatura veritabanında o referansla kayıtlı, olmayan fatura hiç yok.
function Test-DbLookup([string]$Title, [string]$InvoiceNumber, [string]$Reference, [string]$MissingInvoiceNumber) {
    Write-DbHeader $Title "Kayıtlı: $InvoiceNumber, olmayan: $MissingInvoiceNumber"
    Show-Query ("SELECT invoice_number, erp_reference, behavior, received_at FROM invoices " +
        "WHERE invoice_number IN ('$InvoiceNumber', '$MissingInvoiceNumber') ORDER BY id;")

    $dbReference = Get-SqlScalar "SELECT erp_reference FROM invoices WHERE invoice_number = '$InvoiceNumber' ORDER BY id LIMIT 1;"
    $missing = [int](Get-SqlScalar "SELECT count(*) FROM invoices WHERE invoice_number = '$MissingInvoiceNumber';")

    Write-Host ''
    Write-DbVerdict "kayıtlı faturanın referansı GET ile aynı ($Reference), olmayan fatura 0 kayıt" `
        "veritabanındaki referans: $(if ($dbReference) { $dbReference } else { 'yok' }), olmayan fatura: $missing kayıt" `
        ($dbReference -and $dbReference -eq $Reference -and $missing -eq 0)
}
