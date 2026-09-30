# Gün 2 - Madde 6: Geç cevap oranı %100 iken bir fatura oluştur.
# Servis 10 sn'de Başarısız yazar; fatura simülatörde de kayıtlıdır (30 sn dolduktan sonra tekrar bakılır).
. "$PSScriptRoot\_common.ps1"

Write-Title '6) Geç cevap %100 -> servis 10 sn''de Başarısız, fatura simülatörde kayıtlı'

Restart-Simulator @{
    Simulator__Rates__Success       = 0
    Simulator__Rates__Busy          = 0
    Simulator__Rates__ServerError   = 0
    Simulator__Rates__SaveThenError = 0
    Simulator__Rates__LateResponse  = 100
}
Wait-Service

$start = Get-Date
Write-Step "POST $ServiceUrl/api/v1/invoices  (başlangıç $($start.ToString('HH:mm:ss')))"
$r = New-ServiceInvoice
Write-ServiceResult $r

Write-Step 'Servis veritabanı'
Invoke-ServiceSql ("SELECT invoice_number, status, erp_reference, last_error, send_attempt_count, " +
    "round(extract(epoch FROM updated_at - created_at)::numeric, 2) AS saniye FROM invoices " +
    "WHERE invoice_number = '$($r.InvoiceNumber)';") | Out-Host

$early = Get-SimulatorInvoice $r.InvoiceNumber
Write-Step "Simülatör GET, başlangıçtan $([math]::Round(((Get-Date) - $start).TotalSeconds))s sonra"
Write-Host "  $($early.HttpStatus) $($early.Body)"

$wait = 31 - ((Get-Date) - $start).TotalSeconds
if ($wait -gt 0) {
    Write-Step "Simülatörün 30 sn'lik gecikmesi dolsun diye $([math]::Ceiling($wait)) sn bekleniyor"
    Start-Sleep -Seconds ([math]::Ceiling($wait))
}
$late = Get-SimulatorInvoice $r.InvoiceNumber
Write-Step "Simülatör GET, başlangıçtan $([math]::Round(((Get-Date) - $start).TotalSeconds))s sonra"
Write-Host "  $($late.HttpStatus) $($late.Body)"

Write-Step 'Simülatör logu (bu fatura)'
Get-SimulatorLog | Where-Object { $_ -match [regex]::Escape($r.InvoiceNumber) } | ForEach-Object { Write-Host "  $_" }

$passed = $r.Status -eq 'Başarısız' -and $r.Seconds -ge 9.5 -and $r.Seconds -lt 12 -and $r.LastError -match 'zaman aşımı' -and
    $late.HttpStatus -eq 200 -and $late.RecordCount -eq 1
Write-Result $passed ("servis $($r.Seconds) sn'de $($r.Status) yazdı; 30 sn sonra simülatörde $($late.RecordCount) kayıt " +
    "($($late.References -join ','))")

Restart-Simulator
