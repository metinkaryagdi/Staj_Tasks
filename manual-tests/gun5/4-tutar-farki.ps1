# Gün 5 - Kontrol listesi 4: simülatörün veritabanında bir faturanın tutarını elle değiştir.
# Mutabakat tutar farkı olarak raporlar; iki tarafta da hiçbir şey değişmez. ~1 dk.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: $_ - simülatör ve servis varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Restart-Simulator; Restart-InvoiceService } catch { }; break }

Write-Title 'Kontrol listesi 4) Simülatörde elle değiştirilen tutar: tutar farkı olarak raporlanıyor'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
Restart-Simulator (Get-SimSettings -NoEvents)
Restart-InvoiceService
$number = New-SentInvoice
$serviceBefore = (@(Get-ServiceRows "SELECT status, amount, erp_reference, updated_at FROM invoices WHERE invoice_number = '$number';") -join ';')

Write-Step "Simülatörün veritabanında $number faturasının tutarı elle 10 artırılıyor"
Invoke-Sql "UPDATE invoices SET amount = amount + 10 WHERE invoice_number = '$number';" | Out-Null
Show-ErpQuery "SELECT invoice_number, erp_reference, amount FROM invoices WHERE invoice_number = '$number';"
$erpBefore = (@(Get-ErpRows "SELECT erp_reference, amount FROM invoices WHERE invoice_number = '$number';") -join ';')

Write-Step 'Mutabakat elle başlatılıyor'
$run = Invoke-Reconciliation
$id = $run.run.id
Write-Host "  çalışma ${id}: $($run.run.status)"

Write-DbHeader 'Fatura Servisi' 'Bulgu ve faturanın kendisi'
Show-Findings $id "AND invoice_number = '$number'"
Show-ServiceQuery "SELECT invoice_number, status, amount, erp_reference, updated_at FROM invoices WHERE invoice_number = '$number';"
$finding = @(Get-ServiceRows "SELECT finding_type, action, details FROM reconciliation_findings WHERE run_id = $id AND invoice_number = '$number';")
$serviceAfter = (@(Get-ServiceRows "SELECT status, amount, erp_reference, updated_at FROM invoices WHERE invoice_number = '$number';") -join ';')
$erpAfter = (@(Get-ErpRows "SELECT erp_reference, amount FROM invoices WHERE invoice_number = '$number';") -join ';')

Check (Write-DbVerdict 'bulgu: Alan Farkı / Raporlandı, ayrıntıda tutar' ($finding -join ' ; ') `
    ($finding.Count -eq 1 -and $finding[0] -like 'Alan Farkı|Raporlandı|tutar:*'))
Check (Write-DbVerdict 'serviste fatura aynı (durum, tutar, referans, updated_at)' $serviceAfter ($serviceAfter -eq $serviceBefore))
Check (Write-DbVerdict 'simülatördeki kayıt değişmedi (tutar elle değiştirdiğimiz hâlde kaldı)' $erpAfter ($erpAfter -eq $erpBefore))

Restart-Simulator
Write-Result $allPassed 'tutar farkı raporlandı, iki tarafta hiçbir şey değişmedi'
