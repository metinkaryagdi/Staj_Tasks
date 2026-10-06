# Gün 3 (Güvenli Gönderim) script'lerinin ortak yardımcıları. Gün 2'nin gun2\_common.ps1'ini de yükler
# (Wait-Service, Get-ServiceRows, Show-ServiceQuery, Write-DbVerdict ...). Doğrudan çalıştırılmaz.
param([switch]$WithWebhooks)

. "$PSScriptRoot\..\gun2\_common.ps1"

# Gün 3 yalnızca fatura gönderimini sınar; Gün 4 haberleri durumları ilerletmesin.
# Gün 4 bu dosyayı -WithWebhooks ile yükler ve Gün 1'in özgün yardımcısını kullanır.
if (-not $WithWebhooks) {
    $script:BaseRestartSimulator = (Get-Command Restart-Simulator).ScriptBlock
    function Restart-Simulator([hashtable]$Settings = @{}) {
        $quietSettings = @{}
        foreach ($key in $Settings.Keys) { $quietSettings[$key] = $Settings[$key] }
        $quietSettings['Webhooks__Enabled'] = 'false'
        & $script:BaseRestartSimulator $quietSettings
    }

    # stop/start kullanan script'ler de son up ayarını devralır; ilk fatura öncesinde kapat.
    Restart-Simulator
}

# Gün 1'deki Write-Result ile aynı çıktı; ek olarak sonucu adimlar.ps1'in özet tablosu için saklar.
function Write-Result([bool]$Passed, [string]$Text) {
    $global:Gun3LastResult = $Passed
    Write-Host ''
    if ($Passed) { Write-Host "SONUÇ: GEÇTİ  - $Text" -ForegroundColor Green }
    else         { Write-Host "SONUÇ: KALDI  - $Text" -ForegroundColor Red }
}

# Çift tırnaklı tanımlayıcı içeren SQL için ("__EFMigrationsHistory"): PowerShell 5.1 native komut argümanlarındaki
# çift tırnakları siler, bu yüzden SQL psql'e argümanla değil stdin'den verilir.
function Invoke-ServiceSqlStdin([string]$Sql, [switch]$Rows) {
    Push-Location $RepoRoot
    try {
        $psqlArgs = @('compose', 'exec', '-T', 'invoice-db', 'psql', '-U', 'invoice', '-d', 'invoice_service', '-v', 'ON_ERROR_STOP=1')
        if ($Rows) { $psqlArgs += @('-tA', '-F', '|') }
        $output = @($Sql | & docker @psqlArgs | Where-Object { $_ })
        if ($LASTEXITCODE -ne 0) { throw "Fatura Servisi veritabanı sorgusu başarısız oldu (psql çıkış kodu $LASTEXITCODE): $Sql" }
        $output
    }
    finally { Pop-Location }
}

# SQL'i BEGIN ... ROLLBACK içinde çalıştırır: veritabanında hiçbir iz bırakmaz, yalnızca kabul edilip edilmediğini döner.
# Reddedildiyse PostgreSQL'in hata satırını da döner.
function Test-ServiceSql([string]$Sql) {
    Push-Location $RepoRoot
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& docker compose exec -T invoice-db psql -U invoice -d invoice_service -v ON_ERROR_STOP=1 -q `
            -c 'BEGIN;' -c $Sql -c 'ROLLBACK;' 2>&1 | ForEach-Object { "$_" })
        [pscustomobject]@{
            Accepted = $LASTEXITCODE -eq 0
            Error    = ($output | Where-Object { $_ -match 'ERROR' } | Select-Object -First 1)
        }
    }
    finally {
        $ErrorActionPreference = $previous
        Pop-Location
    }
}

# Servisin GET /api/v1/invoices?status=... endpoint'i: o durumdaki faturaların numaraları. Cevap sayfalıdır
# ({items, totalPages, ...}); bütün sayfalar 100'erli okunur.
function Get-ServiceInvoiceNumbers([string]$Status) {
    $numbers = @()
    $page = 1
    do {
        $url = "$ServiceUrl/api/v1/invoices?status=$([Uri]::EscapeDataString($Status))&page=$page&pageSize=100"
        $response = $script:Http.GetAsync($url).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw "GET $url -> $([int]$response.StatusCode): $body" }
        $json = $body | ConvertFrom-Json
        $numbers += @($json.items | ForEach-Object { $_.invoiceNumber })
        $page++
    } while ($page -le $json.totalPages)
    $numbers
}

# Aralıktaki faturaların hepsi Bekliyor'dan çıkana kadar (gönderildi ya da başarısız) bekler; geçen saniyeyi döner.
# Servisin GET /api/v1/invoices?status=Bekliyor endpoint'ini kullanır. Süre dolarsa durur: kuyruğun boşalmaması
# bir hatadır, sessizce geçilmez.
function Wait-QueueDrained([string]$From, [string]$To, [int]$TimeoutSeconds = 300) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $last = -1
    while ($true) {
        $pending = @(Get-ServiceInvoiceNumbers 'Bekliyor' | Where-Object { $_ -ge $From -and $_ -le $To }).Count
        if ($pending -eq 0) { return [math]::Round($watch.Elapsed.TotalSeconds, 1) }
        if ($pending -ne $last) { Write-Host ('  {0,5:N0} sn: {1} fatura Bekliyor' -f $watch.Elapsed.TotalSeconds, $pending) -ForegroundColor DarkGray }
        $last = $pending
        if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw "Kuyruk $TimeoutSeconds sn içinde boşalmadı ($pending fatura Bekliyor)." }
        Start-Sleep -Milliseconds 500
    }
}

# $Count fatura oluşturur, hepsinin 202 dönmesini bekler; ilk ve son fatura numarasını döner.
function New-ServiceInvoices([int]$Count) {
    $numbers = @()
    $bad = 0
    for ($i = 0; $i -lt $Count; $i++) {
        $r = New-ServiceInvoice
        if ($r.HttpStatus -ne 202) { $bad++ }
        $numbers += $r.InvoiceNumber
    }
    Write-Host "  $Count fatura oluşturuldu: $($numbers[0]) .. $($numbers[-1]), 202 olmayan cevap: $bad"
    if ($bad -gt 0) { throw "$bad fatura 202 almadı." }
    [pscustomobject]@{ From = $numbers[0]; To = $numbers[-1] }
}

# Servis logundan verilen faturaların denemelerini çıkarır: her deneme için başlangıç/bitiş, HTTP sonucu, Retry-After,
# planlanan bekleme (wait) ve bir önceki denemenin bitişinden bu denemenin başlangıcına kadar gerçekten geçen süre.
# Başlangıç ve sonuç satırları alım kimliğiyle (log'daki claim=, erp_outbox.claim_token) eşlenir: her alımın kimliği
# farklıdır. Resend deneme numarasını 1'e döndürdüğü, yarıda kalan son deneme aynı numarayla yeniden alındığı ve iki
# kopya aynı faturayı farklı zamanlarda alabildiği için "fatura + deneme numarası" bir denemeyi ayırt etmez.
# Denemeler zamana göre sıralanır.
function Get-SendAttempts([string[]]$Invoices) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $starts = @{}
    $rows = @()
    foreach ($line in Get-ServiceLog) {
        if ($line -match '^(\S+ \S+) info: .*ERP send start invoice=(\S+) attempt=(\d+)/\d+ worker=\S+ claim=(\w+)') {
            if ($Invoices -contains $Matches[2]) { $starts[$Matches[4]] = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss.fff', $inv) }
            continue
        }
        elseif ($line -match '^(\S+ \S+) info: .*ERP send invoice=(\S+) attempt=(\d+)/\d+ worker=(\S+) claim=(\w+) check=(\S+) outcome=(\w+) http=(\S+) retryAfter=(.*?) wait=([\d.]+)s reason=') {
            if ($Invoices -notcontains $Matches[2]) { continue }
            $start = $starts[$Matches[5]]
            $starts.Remove($Matches[5])
            $rows += [pscustomobject]@{
                Invoice = $Matches[2]; Attempt = [int]$Matches[3]; Worker = $Matches[4]; Claim = $Matches[5]; Check = $Matches[6]
                Outcome = $Matches[7]; Http = $Matches[8]; RetryAfter = $Matches[9]; Wait = [double]::Parse($Matches[10], $inv)
                End = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss.fff', $inv); Start = $start; WaitedBefore = $null
            }
        }
    }
    $rows = @($rows | Sort-Object Invoice, End)
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = $rows[$i]
        if ($i -gt 0 -and $rows[$i - 1].Invoice -eq $r.Invoice -and $r.Start) {
            $r.WaitedBefore = [math]::Round(($r.Start - $rows[$i - 1].End).TotalSeconds, 3)
        }
    }
    $rows
}

function Show-SendAttempts($Attempts) {
    Write-Host ''
    Write-Host ('  {0,-12} {1,7} {2,-9} {3,-10} {4,-5} {5,-31} {6,10} {7,16}' -f 'Fatura', 'Deneme', 'Kontrol', 'Sonuç', 'HTTP', 'Retry-After', 'Plan (sn)', 'Önce bekl. (sn)') -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 108)) -ForegroundColor Cyan
    foreach ($a in $Attempts) {
        $waited = if ($null -ne $a.WaitedBefore) { '{0:N3}' -f $a.WaitedBefore } else { '-' }
        Write-Host ('  {0,-12} {1,7} {2,-9} {3,-10} {4,-5} {5,-31} {6,10:N3} {7,16}' -f $a.Invoice, "$($a.Attempt)/10", $a.Check, $a.Outcome, $a.Http, $a.RetryAfter, $a.Wait, $waited)
    }
    Write-Host '  Kontrol: first = ilk gönderim (doğrudan POST); found = simülatörde zaten var, POST yapılmadı; notFound = yok, POST yapıldı; unknown = sorulamadı, POST yapılmadı.' -ForegroundColor DarkGray
    Write-Host '  Plan: bu denemeden sonra beklenecek süre. Önce bekl.: önceki denemenin bitişinden bu denemenin başlangıcına geçen süre.' -ForegroundColor DarkGray
}

# Faturanın 9. denemesi bitene kadar bekler (outbox attempt_count 9 ve kilit bırakılmış): 10. ve son deneme
# ~59 sn sonra başlayacak. Son deneme senaryolarını (ek1, adim6) kurmak için.
function Wait-NinthAttemptDone([string]$Number) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $row = @(Get-ServiceRows "SELECT attempt_count, locked_until IS NULL FROM erp_outbox WHERE invoice_number = '$Number';")[0] -split '\|'
        if ([int]$row[0] -ge 9 -and $row[1] -eq 't') { return }
        if ($watch.Elapsed.TotalSeconds -gt 420) { throw "$Number 9. denemeyi 420 sn içinde bitirmedi." }
        Start-Sleep -Milliseconds 500
    }
}
