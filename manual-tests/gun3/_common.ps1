# Gün 3 (Güvenli Gönderim) script'lerinin ortak yardımcıları. Gün 2'nin gun2\_common.ps1'ini de yükler
# (Wait-Service, Get-ServiceRows, Show-ServiceQuery, Write-DbVerdict ...). Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun2\_common.ps1"

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

# Aralıktaki faturaların hepsi Bekliyor'dan çıkana kadar (gönderildi ya da başarısız) bekler; geçen saniyeyi döner.
# Süre dolarsa durur: kuyruğun boşalmaması bir hatadır, sessizce geçilmez.
function Wait-QueueDrained([string]$From, [string]$To, [int]$TimeoutSeconds = 300) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $range = "invoice_number BETWEEN '$From' AND '$To'"
    $last = -1
    while ($true) {
        $pending = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE $range AND status = 'Bekliyor';")[0]
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
function Get-SendAttempts([string[]]$Invoices) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $starts = @{}
    $rows = @()
    foreach ($line in Get-ServiceLog) {
        if ($line -match '^(\S+ \S+) info: .*ERP send start invoice=(\S+) attempt=(\d+)/') {
            if ($Invoices -contains $Matches[2]) { $starts["$($Matches[2])#$($Matches[3])"] = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss.fff', $inv) }
        }
        elseif ($line -match '^(\S+ \S+) info: .*ERP send invoice=(\S+) attempt=(\d+)/\d+ worker=(\S+) check=(\S+) outcome=(\w+) http=(\S+) retryAfter=(.*?) wait=([\d.]+)s reason=') {
            if ($Invoices -notcontains $Matches[2]) { continue }
            $rows += [pscustomobject]@{
                Invoice = $Matches[2]; Attempt = [int]$Matches[3]; Worker = $Matches[4]; Check = $Matches[5]; Outcome = $Matches[6]
                Http = $Matches[7]; RetryAfter = $Matches[8]; Wait = [double]::Parse($Matches[9], $inv)
                End = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss.fff', $inv); Start = $null; WaitedBefore = $null
            }
        }
    }
    $rows = @($rows | Sort-Object Invoice, Attempt)
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = $rows[$i]
        $r.Start = $starts["$($r.Invoice)#$($r.Attempt)"]
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
