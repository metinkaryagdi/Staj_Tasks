# Fatura Servisi'nin veritabanını (PostgreSQL, invoice-db) açar.
#   .\manual-tests\gun2\db.ps1                   -> etkileşimli psql oturumu açar (çıkmak için \q)
#   .\manual-tests\gun2\db.ps1 -Sql "SELECT ..."  -> tek bir sorgu çalıştırıp çıkar
# Simülatörün veritabanı için: .\manual-tests\gun1\db.ps1
param([string]$Sql)
. "$PSScriptRoot\_common.ps1"

Push-Location $RepoRoot
try {
    if ($Sql) {
        & docker compose exec -T invoice-db psql -U invoice -d invoice_service -c $Sql
        return
    }

    Write-Host ''
    Write-Host 'Fatura Servisi veritabanı açılıyor (çıkmak için \q yazıp Enter).' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Faydalı sorgular:' -ForegroundColor Yellow
    Write-Host "  SELECT status, count(*) FROM invoices GROUP BY status;"
    Write-Host "  SELECT invoice_number, status, erp_reference, last_error, send_attempt_count FROM invoices ORDER BY invoice_number DESC LIMIT 20;"
    Write-Host "  SELECT send_attempt_count, status, count(*) FROM invoices GROUP BY 1, 2 ORDER BY 1, 2;"
    Write-Host "  SELECT * FROM invoices WHERE invoice_number = 'FTR-000001';"
    Write-Host "  \d invoices        (tablo yapısı)"
    Write-Host ''
    & docker compose exec invoice-db psql -U invoice -d invoice_service
}
finally { Pop-Location }
