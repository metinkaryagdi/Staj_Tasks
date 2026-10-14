# Kontrol listesi 6: bir faturanın bütün log satırları trace_id ile bulunabiliyor.
#   .\manual-tests\gun12\7-loglar-trace-id.ps1                      (yeni bir fatura, simülatörün o anki ayarlarıyla)
#   .\manual-tests\gun12\7-loglar-trace-id.ps1 -InvoiceNumber FTR-000012
# trace_id, faturanın oluşturulduğu satırdan ("Invoice queued invoice=...") okunur. İki servisin logunda bu trace_id'yi
# taşıyan satırlar listelenir; fatura numarasını geçen her satırın bu trace_id'yi taşıdığı kontrol edilir. Loglar
# container'ın logudur: container yeniden oluşturulursa (ör. Restart-Simulator) önceki satırları silinir; bu yüzden
# varsayılan yol yeni bir fatura oluşturur ve haberleri bitene kadar bekler.
param([string]$InvoiceNumber = '')

. "$PSScriptRoot\_common.ps1"

if (-not $InvoiceNumber) {
    Write-Step 'Fatura oluşturuluyor'
    $InvoiceNumber = (New-ServiceInvoice).InvoiceNumber
    Write-Host "  $InvoiceNumber"
    Wait-InvoicesIn @($InvoiceNumber) @('Gönderildi', 'İşleme Alındı', 'Onaylandı', 'Reddedildi', 'Başarısız') 300 'gönderildi' | Out-Null
    Wait-EventsDone @($InvoiceNumber) 180 | Out-Null
}
Write-Title "Kontrol listesi 6: $InvoiceNumber faturasının log satırları"

$all = Get-AllLogLines
$created = @($all | Where-Object { $_ -match "Invoice queued invoice=$InvoiceNumber " })
if ($created.Count -ne 1) { throw "$InvoiceNumber için oluşturma satırı bulunamadı (servis logu)." }
$traceId = [regex]::Match($created[0], 'trace_id=([0-9a-f]{32})').Groups[1].Value
Write-Host "  trace_id=$traceId (oluşturma satırından)"

Write-Step "trace_id=$traceId taşıyan satırlar"
$byTrace = @($all | Where-Object { $_ -match "trace_id=$traceId" })
$byTrace | ForEach-Object { Write-Host ('  ' + ($_ -replace " trace_id=$traceId", '')) }
$byTrace | Set-Content (Join-Path $OutputDir 'gun12-7-loglar-trace-id.txt') -Encoding UTF8

Write-Step 'Sayılar'
$naming = @($all | Where-Object { $_ -match [regex]::Escape($InvoiceNumber) })
$missing = @($naming | Where-Object { $_ -notmatch "trace_id=$traceId" })
$services = $byTrace | ForEach-Object { $_.Split('|')[0].Trim() } | Group-Object | ForEach-Object { "$($_.Name): $($_.Count)" }
Write-Host "  trace_id ile bulunan satır: $($byTrace.Count) ($($services -join ', '))"
Write-Host "  Fatura numarasını geçen satır: $($naming.Count); bunlardan trace_id'yi taşımayan: $($missing.Count)"
$missing | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
$hasSimulator = @($byTrace | Where-Object { $_ -like 'erp-simulator*' }).Count -gt 0
Write-Result ($missing.Count -eq 0 -and $hasSimulator) "Faturanın iki servisteki bütün satırları trace_id=$traceId ile bulunuyor"
Write-Host '  Satırlar: manual-tests\output\gun12-7-loglar-trace-id.txt' -ForegroundColor DarkGray
Write-Host "  Komutla: docker compose logs invoice-service erp-simulator | Select-String trace_id=$traceId" -ForegroundColor DarkGray
