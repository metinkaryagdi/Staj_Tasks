# Simülatörün veritabanını (PostgreSQL) açar.
#   .\manual-tests\db.ps1                 -> etkileşimli psql oturumu açar (çıkmak için \q)
#   .\manual-tests\db.ps1 -Sql "SELECT ..." -> tek bir sorgu çalıştırıp çıkar
param([string]$Sql)
. "$PSScriptRoot\_common.ps1"

Push-Location $RepoRoot
try {
    if ($Sql) {
        & docker compose exec -T erp-db psql -U erp -d erp_simulator -c $Sql
        return
    }

    Write-Host ''
    Write-Host 'ERP simülatör veritabanı açılıyor (çıkmak için \q yazıp Enter).' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Faydalı sorgular:' -ForegroundColor Yellow
    Write-Host "  SELECT count(*) FROM invoices;"
    Write-Host "  SELECT id, invoice_number, erp_reference, behavior, received_at FROM invoices ORDER BY id DESC LIMIT 20;"
    Write-Host "  SELECT behavior, count(*) FROM invoices GROUP BY behavior;"
    Write-Host "  SELECT * FROM invoices WHERE invoice_number LIKE 'T1-%' ORDER BY id;"
    Write-Host "  SELECT invoice_number, count(*) FROM invoices GROUP BY invoice_number HAVING count(*) > 1;"
    Write-Host "  \d invoices        (tablo yapısı)"
    Write-Host ''
    & docker compose exec erp-db psql -U erp -d erp_simulator
}
finally { Pop-Location }
