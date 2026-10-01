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
