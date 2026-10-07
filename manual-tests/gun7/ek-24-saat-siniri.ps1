# Gün 7 - Ek: "Kayıt yok" cevabı 24 saat dolmadan yeniden sorulmuyor, dolunca soruluyor (saat sınırında). ~1,5 dk.
#
#   ERP'ye son sorusu 23 sa 59 dk önce yapılmış, cevabı "Kayıt yok" olan eski bir Başarısız fatura eklenir. Hemen başlatılan
#   mutabakat onu sormamalı; 75 sn sonra (24 saat dolmuş) başlatılan mutabakat sormalı ve sorgu zamanını güncellemeli.
#   Servis ayar dosyasındaki değerlerle (NotFoundRecheckHours 24) çalışır.
. "$PSScriptRoot\_common.ps1"

Write-Title 'Ek) "Kayıt yok" cevabı 24 saat dolmadan sorulmuyor, dolunca soruluyor'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
Write-Host "  Serviste: $(Get-ServiceEnv 'Reconciliation__NotFoundRecheckHours')"

Write-Step 'Başarısız fatura ekleniyor: 3 gün önce oluşturulmuş, ERP''ye son soru 23 sa 59 dk önce, cevap "Kayıt yok"'
$n = New-NotFoundInvoice 'QA7-24SAAT' '23 hours 59 minutes'
Write-Host "  Fatura: $n"
Show-ErpCheck @($n)

Write-Step '1. mutabakat hemen başlatılıyor (24 saat dolmadı)'
$r1 = Invoke-Reconciliation
Write-Host "  çalışma $($r1.run.id): $($r1.run.status)"
$log1 = Get-RunLookups $r1.run.id @($n)
$log1 | ForEach-Object { Write-Host "  log: $_" -ForegroundColor DarkGray }
Show-ErpCheck @($n)
$asked1 = @($log1 | Where-Object { $_ -match "invoice=$n " }).Count
$unchanged = @(Get-ServiceRows "SELECT now() - erp_checked_at > interval '23 hours 58 minutes' FROM invoices WHERE invoice_number = '$n';")[0]
Write-DbHeader 'Fatura Servisi' '1. çalışma: fatura sorulmadı'
Check (Write-DbVerdict 'faturanın log satırı yok' "$asked1 satır" ($asked1 -eq 0))
Check (Write-DbVerdict 'erp_checked_at değişmedi (hâlâ ~23 sa 59 dk önce)' "$unchanged" ($unchanged -eq 't'))

Write-Step '75 sn bekleniyor: ERP''ye son sorunun üzerinden 24 saat geçecek'
Start-Sleep -Seconds 75
Show-ErpCheck @($n)

Write-Step '2. mutabakat başlatılıyor (24 saat doldu)'
$r2 = Invoke-Reconciliation
Write-Host "  çalışma $($r2.run.id): $($r2.run.status)"
$log2 = Get-RunLookups $r2.run.id @($n)
$log2 | ForEach-Object { Write-Host "  log: $_" -ForegroundColor DarkGray }
Show-ErpCheck @($n)
$asked2 = @($log2 | Where-Object { $_ -match "invoice=$n answer=NotFound" }).Count
$updated = @(Get-ServiceRows "SELECT erp_check_result || '|' || (now() - erp_checked_at < interval '2 minutes') FROM invoices WHERE invoice_number = '$n';")[0]
Write-DbHeader 'Fatura Servisi' '2. çalışma: fatura soruldu'
Check (Write-DbVerdict 'faturanın log satırı: answer=NotFound' "$asked2 satır" ($asked2 -eq 1))
Check (Write-DbVerdict 'erp_checked_at az önceye güncellendi, cevap Kayıt yok' "$updated" ($updated -eq 'Kayıt yok|true'))

Write-Result $allPassed 'fatura 24 saat dolmadan sorulmadı, dolunca soruldu'
