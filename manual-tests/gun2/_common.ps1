# Gün 2 (Fatura Servisi) script'lerinin ortak yardımcıları. Gün 1'in gun1\_common.ps1'ini de yükler
# (Restart-Simulator, Write-Title, Invoke-Compose ...). Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun1\_common.ps1"

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
# Sorgu hata verirse durur: "okunamadı" sessizce "hiç satır yok" gibi görünmesin.
function Get-ServiceRows([string]$Sql) {
    Push-Location $RepoRoot
    try {
        $rows = @(& docker compose exec -T invoice-db psql -U invoice -d invoice_service -v ON_ERROR_STOP=1 -tA -F '|' -c $Sql | Where-Object { $_ })
        if ($LASTEXITCODE -ne 0) { throw "Fatura Servisi veritabanı sorgusu başarısız oldu (psql çıkış kodu $LASTEXITCODE): $Sql" }
        $rows
    }
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

# HttpStatus 0: simülatöre hiç ulaşılamadı (bağlantı hatası, zaman aşımı); Error nedenini yazar.
function Get-SimulatorInvoice([string]$InvoiceNumber) {
    try {
        $response = $script:Http.GetAsync("$SimulatorUrl/api/v1/invoices/$InvoiceNumber").GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        return [pscustomobject]@{ HttpStatus = 0; RecordCount = 0; References = @(); Body = ''; Error = $inner.Message }
    }
    # 200 ama gövde okunamıyorsa (bozuk JSON, recordCount yok) kaydın varlığı bilinemez: Error doldurulur,
    # Compare-Invoices bu faturayı "var" saymaz, "sorgulanamadı"ya yazar.
    $data = $null
    $error200 = ''
    if ([int]$response.StatusCode -eq 200) {
        try { $data = $body | ConvertFrom-Json -ErrorAction Stop } catch { }
        if (-not $data -or $null -eq $data.recordCount) { $data = $null; $error200 = 'cevap gövdesi okunamadı' }
    }
    [pscustomobject]@{
        HttpStatus  = [int]$response.StatusCode
        RecordCount = if ($data) { [int]$data.recordCount } else { 0 }
        References  = if ($data) { @($data.records | ForEach-Object { $_.erpReference }) } else { @() }
        Body        = $body
        Error       = $error200
    }
}

function Write-ServiceResult($r) {
    $color = if ($r.Status -eq 'Gönderildi') { 'Green' } else { 'Red' }
    $detail = if ($r.Status -eq 'Gönderildi') { "erpReference=$($r.ErpReference)" } else { "lastError=$($r.LastError)" }
    Write-Host ('  {0,-12} -> {1} {2,-10} deneme={3}  süre={4}s  {5}' -f `
        $r.InvoiceNumber, $r.HttpStatus, $r.Status, $r.Attempts, $r.Seconds, $detail) -ForegroundColor $color
}

function Get-ServiceLog {
    Push-Location $RepoRoot
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & docker compose logs invoice-service --no-log-prefix 2>$null }
    finally { $ErrorActionPreference = $previous; Pop-Location }
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
# Simülatörde "var" = gövdesi okunabilen 200, "yok" = yalnızca 404. Başka bir cevap (500 vb.), okunamayan 200 ya da
# bağlantı hatası faturanın ERP'de olup olmadığını söylemez: o fatura "var"/"yok" sayılmaz, "sorgulanamadı" satırına yazılır.
# -From / -To yalnızca FTR-000001 biçiminde kabul edilir; veritabanı sorgusu hata verirse script durur.
# ---------------------------------------------------------------------------
function Compare-Invoices([string]$From, [string]$To, [switch]$Quiet) {
    $where = @()
    foreach ($bound in @($From, $To) | Where-Object { $_ }) {
        if ($bound -notmatch '^FTR-\d{6,}$') { throw "Geçersiz fatura numarası: '$bound' (beklenen biçim: FTR-000001)" }
    }
    if ($From) { $where += "invoice_number >= '$From'" }
    if ($To)   { $where += "invoice_number <= '$To'" }
    $whereSql = if ($where) { 'WHERE ' + ($where -join ' AND ') } else { '' }

    $rows = @(Get-ServiceRows ("SELECT invoice_number, status, coalesce(erp_reference, ''), send_attempt_count " +
        "FROM invoices $whereSql ORDER BY invoice_number;"))

    $result = [ordered]@{
        Total = 0; SentFound = 0; SentMissing = 0; FailedMissing = 0; FailedFound = 0
        MultipleRecords = 0; ReferenceMatches = 0; SimulatorRecords = 0; Unknown = 0; Details = @()
    }
    foreach ($row in $rows) {
        $number, $status, $reference, $attempts = $row -split '\|'
        $sim = Get-SimulatorInvoice $number
        $found = $sim.HttpStatus -eq 200 -and -not $sim.Error
        $missing = $sim.HttpStatus -eq 404
        $result.Total++

        if (-not $found -and -not $missing) {
            $result.Unknown++
        }
        else {
            $result.SimulatorRecords += $sim.RecordCount
            if ($sim.RecordCount -gt 1) { $result.MultipleRecords++ }

            if ($status -eq 'Gönderildi') {
                if ($found) { $result.SentFound++ } else { $result.SentMissing++ }
                if ($found -and $sim.References -contains $reference) { $result.ReferenceMatches++ }
            }
            elseif ($found) { $result.FailedFound++ }
            else { $result.FailedMissing++ }
        }

        $result.Details += [pscustomobject]@{
            Invoice = $number; Status = $status; Attempts = [int]$attempts; ServiceReference = $reference
            SimulatorHttp = $sim.HttpStatus; SimulatorRecords = $sim.RecordCount
            SimulatorReferences = ($sim.References -join ','); SimulatorError = $sim.Error
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
    $unknownColor = if ($c.Unknown -gt 0) { 'Yellow' } else { 'Gray' }
    Write-Host ('  {0,-46} {1,12}' -f 'Simülatöre sorulamadı (geçerli cevap yok)', $c.Unknown) -ForegroundColor $unknownColor
    Write-Host ('  ' + ('-' * 60)) -ForegroundColor Cyan
    Write-Host ('  {0,-46} {1,12}' -f 'Toplam fatura (serviste)', $c.Total)
    Write-Host ('  {0,-46} {1,12}' -f 'Toplam kayıt (simülatörde)', $c.SimulatorRecords)
    Write-Host ('  {0,-46} {1,12}' -f 'erp_reference simülatördekiyle aynı', "$($c.ReferenceMatches)/$($c.SentFound + $c.SentMissing)")

    if ($c.Unknown -gt 0) {
        Write-Host ''
        Write-Host "  UYARI: $($c.Unknown) fatura simülatöre sorulamadı; bunlar 'var' ya da 'yok' sayılmadı, tablo eksik." -ForegroundColor Yellow
        $c.Details | Where-Object { $_.SimulatorHttp -notin 200, 404 -or $_.SimulatorError } | Select-Object -First 5 | ForEach-Object {
            $why = if ($_.SimulatorHttp -eq 0) { "bağlantı hatası: $($_.SimulatorError)" }
                   elseif ($_.SimulatorError) { "HTTP $($_.SimulatorHttp), $($_.SimulatorError)" }
                   else { "HTTP $($_.SimulatorHttp)" }
            Write-Host "    $($_.Invoice): $why" -ForegroundColor Yellow
        }
        if ($c.Unknown -gt 5) { Write-Host "    ... ve $($c.Unknown - 5) fatura daha" -ForegroundColor Yellow }
    }
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

# ---------------------------------------------------------------------------
# Veritabanı kontrolleri (Gün 1'deki gibi): çalıştırılan SQL, gelen tablo, beklenen/gelen.
# İki veritabanı ayrı olduğu için tek sorguda birleştirilemez: her kontrol önce servisin (invoice-db),
# sonra simülatörün (erp-db) tablosunu gösterir, karşılaştırmayı PowerShell tarafında yapar.
# Script'ler veritabanlarına docker üzerinden bağlanır; uygulamalar birbirinin veritabanını yine görmez.
# ---------------------------------------------------------------------------

function Show-ServiceQuery([string]$Sql) {
    Write-Host ''
    Write-Host "Fatura Servisi (invoice-db) SQL: $Sql" -ForegroundColor DarkGray
    Invoke-ServiceSql $Sql | Out-Host
}

function Show-ErpQuery([string]$Sql) {
    Write-Host ''
    Write-Host "ERP Simülatörü (erp-db) SQL: $Sql" -ForegroundColor DarkGray
    Invoke-Sql $Sql | Out-Host
}

function Get-ErpRows([string]$Sql) {
    Push-Location $RepoRoot
    try {
        $rows = @(& docker compose exec -T erp-db psql -U erp -d erp_simulator -v ON_ERROR_STOP=1 -tA -F '|' -c $Sql | Where-Object { $_ })
        if ($LASTEXITCODE -ne 0) { throw "Simülatör veritabanı sorgusu başarısız oldu (psql çıkış kodu $LASTEXITCODE): $Sql" }
        $rows
    }
    finally { Pop-Location }
}

function Write-ServiceManualQuery([string]$Sql) {
    Write-Host "  Kayıtları tek tek görmek için: .\manual-tests\gun2\db.ps1 -Sql `"$Sql`"" -ForegroundColor DarkGray
}

# Karşılaştırma tablosunu HTTP yerine doğrudan iki veritabanından hesaplar.
# Karşılaştırma script'inin (simülatörün GET endpoint'i) sonucuyla aynı çıkmalı.
function Get-DbComparison([string]$From, [string]$To) {
    $range = "invoice_number BETWEEN '$From' AND '$To'"
    $erp = @{}
    foreach ($row in @(Get-ErpRows "SELECT invoice_number, count(*), string_agg(erp_reference, ',' ORDER BY id) FROM invoices WHERE $range GROUP BY 1;")) {
        $number, $count, $refs = $row -split '\|'
        $erp[$number] = @{ Count = [int]$count; References = @($refs -split ',') }
    }

    # Veritabanında "sorgulanamadı" durumu yoktur; HTTP karşılaştırmasında sorgulanamayan fatura varsa iki sonuç farklı çıkar.
    $c = [ordered]@{ Total = 0; SentFound = 0; SentMissing = 0; FailedMissing = 0; FailedFound = 0
                     MultipleRecords = 0; ReferenceMatches = 0; SimulatorRecords = 0; Unknown = 0 }
    foreach ($row in @(Get-ServiceRows "SELECT invoice_number, status, coalesce(erp_reference, '') FROM invoices WHERE $range;")) {
        $number, $status, $reference = $row -split '\|'
        $found = $erp.ContainsKey($number)
        $c.Total++
        if ($found) {
            $c.SimulatorRecords += $erp[$number].Count
            if ($erp[$number].Count -gt 1) { $c.MultipleRecords++ }
        }
        if ($status -eq 'Gönderildi') {
            if ($found) { $c.SentFound++ } else { $c.SentMissing++ }
            if ($found -and $erp[$number].References -contains $reference) { $c.ReferenceMatches++ }
        }
        elseif ($found) { $c.FailedFound++ }
        else { $c.FailedMissing++ }
    }
    [pscustomobject]$c
}

function Format-Comparison($c) {
    "Gönderildi+var $($c.SentFound), Başarısız+yok $($c.FailedMissing), Başarısız+var $($c.FailedFound), " +
    "Gönderildi+yok $($c.SentMissing), birden fazla kayıt $($c.MultipleRecords), simülatörde $($c.SimulatorRecords) kayıt, " +
    "sorgulanamadı $($c.Unknown)"
}

# Madde 2: serviste hepsi Gönderildi, simülatörde her fatura tek kayıt, fatura no -> erp_reference çiftleri birebir aynı.
function Test-DbAllSent([string]$Title, [string]$From, [string]$To, [int]$Count) {
    Write-DbHeader $Title "Fatura aralığı: $From .. $To"
    $range = "invoice_number BETWEEN '$From' AND '$To'"

    Show-ServiceQuery ("SELECT status, count(*) AS kayit, count(DISTINCT erp_reference) AS farkli_referans, " +
        "min(erp_reference) AS ilk_referans, max(erp_reference) AS son_referans FROM invoices WHERE $range GROUP BY status;")
    Show-ErpQuery ("SELECT behavior, count(*) AS kayit, count(DISTINCT invoice_number) AS farkli_fatura, " +
        "min(erp_reference) AS ilk_referans, max(erp_reference) AS son_referans FROM invoices WHERE $range GROUP BY behavior;")
    Write-ServiceManualQuery "SELECT invoice_number, status, erp_reference FROM invoices WHERE $range ORDER BY 1;"

    $servicePairs = @(Get-ServiceRows "SELECT invoice_number || '=' || coalesce(erp_reference, '-') FROM invoices WHERE $range AND status = 'Gönderildi' ORDER BY 1;")
    $erpPairs = @(Get-ErpRows "SELECT invoice_number || '=' || erp_reference FROM invoices WHERE $range ORDER BY 1;")
    $same = @($servicePairs | Where-Object { $erpPairs -contains $_ }).Count

    Write-Host ''
    Write-DbVerdict "serviste $Count Gönderildi, simülatörde $Count kayıt, $Count fatura no = erp_reference çifti iki tarafta aynı" `
        "serviste $($servicePairs.Count) Gönderildi, simülatörde $($erpPairs.Count) kayıt, $same çift aynı" `
        ($servicePairs.Count -eq $Count -and $erpPairs.Count -eq $Count -and $same -eq $Count)
}

# Madde 3: servisteki durum/hata dağılımı ile simülatörün kaydettiği davranışlar; tablo veritabanından yeniden hesaplanır.
function Test-DbDefaultRun([string]$Title, [string]$From, [string]$To, $HttpComparison) {
    Write-DbHeader $Title "Fatura aralığı: $From .. $To"
    $range = "invoice_number BETWEEN '$From' AND '$To'"

    Show-ServiceQuery ("SELECT status, CASE WHEN last_error IS NULL THEN '-' WHEN last_error LIKE '%zaman aşımı%' THEN 'zaman aşımı' " +
        "ELSE substring(last_error FROM '^ERP ([0-9]{3})') END AS hata, count(*) AS fatura FROM invoices WHERE $range GROUP BY 1, 2 ORDER BY 1, 2;")
    Show-ErpQuery ("SELECT behavior, count(*) AS kayit FROM invoices WHERE $range GROUP BY behavior ORDER BY behavior;")
    Write-Host '  (Busy ve ServerError simülatörde kayıt açmaz; SaveThenError ve LateResponse açar ama servise başarı dönmez.)' -ForegroundColor DarkGray

    $db = Get-DbComparison $From $To
    Write-Host ''
    Write-DbVerdict "veritabanlarından hesaplanan tablo, karşılaştırma script'iyle (HTTP) aynı: $(Format-Comparison $HttpComparison)" `
        (Format-Comparison $db) ((Format-Comparison $db) -eq (Format-Comparison $HttpComparison))
}

# Madde 4: resend sonrası deneme sayıları ve simülatörde birden fazla kaydı olan faturalar.
function Test-DbResend([string]$Title, [string]$From, [string]$To, $HttpComparison) {
    Write-DbHeader $Title "Fatura aralığı: $From .. $To"
    $range = "invoice_number BETWEEN '$From' AND '$To'"

    Show-ServiceQuery ("SELECT status, send_attempt_count AS deneme, count(*) AS fatura FROM invoices " +
        "WHERE $range GROUP BY 1, 2 ORDER BY 1, 2;")
    Show-ErpQuery ("SELECT invoice_number, count(*) AS kayit, string_agg(erp_reference || ' ' || behavior, ', ' ORDER BY id) AS kayitlar " +
        "FROM invoices WHERE $range GROUP BY invoice_number HAVING count(*) > 1 ORDER BY invoice_number;")

    $db = Get-DbComparison $From $To
    Write-Host ''
    Write-DbVerdict "veritabanlarından hesaplanan tablo, karşılaştırma script'iyle (HTTP) aynı: $(Format-Comparison $HttpComparison)" `
        (Format-Comparison $db) ((Format-Comparison $db) -eq (Format-Comparison $HttpComparison))
}

# Madde 5: fatura serviste Başarısız olarak var, simülatöre hiç ulaşmadığı için erp-db'de yok.
function Test-DbErpDown([string]$Title, [string]$InvoiceNumber) {
    Write-DbHeader $Title "Fatura numarası: $InvoiceNumber"
    Show-ServiceQuery ("SELECT invoice_number, status, erp_reference, last_error, send_attempt_count, created_at, updated_at " +
        "FROM invoices WHERE invoice_number = '$InvoiceNumber';")
    Show-ErpQuery "SELECT count(*) AS kayit FROM invoices WHERE invoice_number = '$InvoiceNumber';"

    $status = @(Get-ServiceRows "SELECT status FROM invoices WHERE invoice_number = '$InvoiceNumber';")
    $erpCount = [int](@(Get-ErpRows "SELECT count(*) FROM invoices WHERE invoice_number = '$InvoiceNumber';")[0])

    Write-Host ''
    Write-DbVerdict 'serviste 1 kayıt (Başarısız), simülatörde 0 kayıt' `
        "serviste $($status.Count) kayıt ($(if ($status) { $status[0] } else { '-' })), simülatörde $erpCount kayıt" `
        ($status.Count -eq 1 -and $status[0] -eq 'Başarısız' -and $erpCount -eq 0)
}

# Madde 6: serviste 10 sn sonra Başarısız; simülatörde isteğin geldiği anda LateResponse olarak kayıtlı.
function Test-DbLateResponse([string]$Title, [string]$InvoiceNumber) {
    Write-DbHeader $Title "Fatura numarası: $InvoiceNumber"
    Show-ServiceQuery ("SELECT invoice_number, status, erp_reference, last_error, created_at, updated_at, " +
        "round(extract(epoch FROM updated_at - created_at)::numeric, 2) AS saniye FROM invoices WHERE invoice_number = '$InvoiceNumber';")
    Show-ErpQuery "SELECT id, invoice_number, erp_reference, behavior, received_at FROM invoices WHERE invoice_number = '$InvoiceNumber' ORDER BY id;"

    $service = @(Get-ServiceRows ("SELECT status, round(extract(epoch FROM updated_at - created_at)::numeric, 2), " +
        "extract(epoch FROM created_at) FROM invoices WHERE invoice_number = '$InvoiceNumber';"))
    $erp = @(Get-ErpRows "SELECT behavior, extract(epoch FROM received_at) FROM invoices WHERE invoice_number = '$InvoiceNumber';")
    $status, $seconds, $createdEpoch = if ($service) { $service[0] -split '\|' } else { '', '0', '0' }
    $behavior, $receivedEpoch = if ($erp) { $erp[0] -split '\|' } else { '', '0' }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $gap = [math]::Round([double]::Parse($receivedEpoch, $inv) - [double]::Parse($createdEpoch, $inv), 2)

    Write-Host ''
    Write-DbVerdict 'serviste ~10 sn sonra Başarısız; simülatörde 1 LateResponse kaydı, servis faturayı oluşturduktan hemen sonra yazılmış' `
        "serviste $status ($seconds sn); simülatörde $($erp.Count) kayıt ($behavior), servis kaydından $gap sn sonra" `
        ($status -eq 'Başarısız' -and [double]::Parse($seconds, $inv) -ge 9.5 -and $erp.Count -eq 1 -and $behavior -eq 'LateResponse' -and [math]::Abs($gap) -lt 2)
}
