# Kontrol listesi 1: tek faturanın GET'ine 500 dönen küçük vekil (erp-vekil.py) servisle simülatör arasına girer. Mutabakat çalışır; bulgu API'den
# okunur, ekran görüntüsü elle alınır. Vekil yalnız bu test içindir. Çıktı manual-tests\output\gun25\c-cevapsiz.txt.
#   .\manual-tests\gun25\3-cevapsiz-ekran.ps1
. "$PSScriptRoot\_common.ps1"
Use-Gun10Volumes "gun25-cevapsiz-$(Get-Date -Format 'MMddHHmm')"
$env:COMPOSE_FILE = $env:COMPOSE_FILE + ';' + (Join-Path $PSScriptRoot 'compose.vekil.yml')
New-Report 'c-cevapsiz'
Write-Title 'Mutabakatta cevabı alınamayan fatura'
Start-Stack
Restart-Simulator @{ Simulator__Rates__Success = 100; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0; Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0 }
$created = Send-Api POST '/api/v1/invoices' (Get-OrderSystemToken) '{"customerCode":"C-EKRAN","amount":10.50,"currency":"TRY","invoiceDate":"2026-11-06"}'
$number = $created.Json.invoiceNumber
Write-Line "Fatura: $number"
do { Start-Sleep -Seconds 2; $status = Invoke-InvoiceSql "SELECT status FROM invoices WHERE invoice_number = '$number'" } while ($status -eq 'Bekliyor')
# Pencereden eski hale getirilir ki tek başına ERP'ye sorulsun.
Invoke-InvoiceSql "UPDATE invoices SET created_at = now() - interval '200 hours', status = 'Onaylandı' WHERE invoice_number = '$number'" | Out-Null
Get-SqlScalar "UPDATE invoices SET received_at = now() - interval '200 hours' WHERE invoice_number = '$number'" | Out-Null
$number | Set-Content -Encoding ascii (Join-Path $PSScriptRoot 'vekil-numara.txt')
foreach ($run in 1, 2) {
    $state = Invoke-ReconciliationRetry
    $detail = (Send-Api GET "/api/v1/reconciliation-runs/$($state.id)" (Get-UserToken 'izleyici')).Json
    $f = @($detail.findings | Where-Object { $_.invoiceNumber -eq $number })
    Check ($state.status -eq 'Tamamlandı' -and $state.reportedCount -ge 1) "Çalışma $($state.id): $($state.status), raporlanan $($state.reportedCount)"
    Check ($f.Count -eq 1 -and $f[0].findingType -eq 'Cevap Alınamadı' -and $f[0].action -eq 'Raporlandı') "Bulgu: $($f[0].findingType), $($f[0].action): $($f[0].details)"
}
Write-Line "Ekran: http://localhost:5100/mutabakat"
Remove-Item (Join-Path $PSScriptRoot 'vekil-numara.txt')
Save-Report
