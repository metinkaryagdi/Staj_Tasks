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
