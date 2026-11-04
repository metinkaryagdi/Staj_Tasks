# İptal (2/2): kontrol listesinin 1-5. maddeleri canlı sistemde. Her bölüm simülatörü o maddenin koşuluna göre yeniden başlatır ve
# sonucu iki veritabanından okur. Çıktı manual-tests\output\gun23\<-Etiket>.txt. ~20 dk.
#   .\manual-tests\gun23\1-kontrol-listesi.ps1
param([string]$Etiket = 'a-kontrol-listesi')
. "$PSScriptRoot\_common.ps1"

New-Report $Etiket
Write-Title 'İptal (2/2): kontrol listesi 1-5'
Start-Stack
Write-Line "Koşu: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

# ---------------------------------------------------------------------------------------------------------------------
Write-Line ''
Write-Line '1) ERP bütün deneme süresince kapalıyken başarısız biten bir iptal, ERP açıldıktan sonra yeniden denenip tamamlanıyor'
Set-Erp @{ Success = 100 }
$n1 = New-Invoice
Wait-Until { (Get-InvoiceStatus $n1) -eq 'Onaylandı' } 60 "$n1 Onaylandı oldu"
Push-Location $RepoRoot
try { docker compose stop erp-simulator 2>&1 | Out-Null } finally { Pop-Location }
Write-Line "  ERP durduruldu $(Get-Date -Format 'HH:mm:ss')"
$c = Request-Cancel $n1
Check ($c.Status -eq 202) "İptal isteği: HTTP $($c.Status)"
Wait-Until { (Get-Outbox $n1 'İptal') -like 'Başarısız|*' } 480 'Gerçek ayarlarla bütün denemeler bitti, iptal Başarısız oldu'
Show-Rows 'Servis (erp_outbox):' "SELECT $OutboxColumns FROM erp_outbox WHERE invoice_number = '$n1' AND kind = 'İptal'"
Check ((Get-InvoiceStatus $n1) -eq 'Onaylandı') "Fatura ERP kapalıyken: $(Get-InvoiceStatus $n1)"
Push-Location $RepoRoot
try { docker compose start erp-simulator 2>&1 | Out-Null } finally { Pop-Location }
Wait-Until { try { (Invoke-RestMethod "http://localhost:5080/api/v1/invoices/$n1").registered } catch { $false } } 60 'ERP açıldı'
$c = Request-Cancel $n1
Check ($c.Status -eq 202) "Aynı iptal isteği yeniden: HTTP $($c.Status)"
Wait-Until { (Get-Outbox $n1 'İptal') -like 'Tamamlandı|*' } 90 'İptal satırı Tamamlandı oldu'
Wait-Until { (Get-InvoiceStatus $n1) -eq 'İptal Edildi' } 60 'Fatura haberle İptal Edildi oldu'
$erp = Get-SqlScalar "SELECT count(*) FROM cancellations WHERE invoice_number = '$n1'"
Check ($erp -eq '1') "ERP'de iptal kaydı sayısı: $erp"
Show-Invoice $n1
Show-Rows 'Servis (operator_actions):' "SELECT operator_name, action, result FROM operator_actions WHERE invoice_number = '$n1' ORDER BY id"

# ---------------------------------------------------------------------------------------------------------------------
Write-Line ''
Write-Line '2) ERP Simülatöründe iptal edilen bir fatura, planlanmış kararının zamanı geldiğinde de iptal edilmiş olarak kalıyor'
foreach ($case in @(@{ Name = 'red'; Rate = 0 }, @{ Name = 'onay'; Rate = 100 })) {
    Write-Line "  Planlanmış karar: $($case.Name)"
    Set-Erp @{ Success = 100 } @{ 'Webhooks__ApprovalRate' = $case.Rate; 'Webhooks__SecondEventMinSeconds' = 30; 'Webhooks__SecondEventMaxSeconds' = 30 }
    $n2 = New-Invoice
    Wait-Until { (Get-Outbox $n2 'Gönderim') -like 'Tamamlandı|*' } 60 "$n2 ERP'ye ulaştı"
    $c = Request-Cancel $n2
    Check ($c.Status -eq 202) "İptal isteği: HTTP $($c.Status)"
    Wait-Until { (Get-InvoiceStatus $n2) -eq 'İptal Edildi' } 30 'Fatura İptal Edildi oldu'
    Wait-Until { (Get-SqlScalar "SELECT now() > max(occurred_at) + interval '5 seconds' FROM webhook_deliveries WHERE invoice_number = '$n2'") -eq 't' } 60 'Planlanmış kararın zamanı geçti'
    $sent = Get-SqlScalar "SELECT count(*) FROM webhook_deliveries WHERE invoice_number = '$n2' AND event_type IN ('invoice.approved', 'invoice.rejected') AND status <> 'Skipped'"
    Check ($sent -eq '0') "Gönderilmeyen karar dışında karar haberi: $sent"
    $decision = Get-ErpDecision $n2
    Check ($decision -eq 'cancelled') "ERP'nin GET cevabındaki karar: $decision"
    Check ((Get-InvoiceStatus $n2) -eq 'İptal Edildi') "Serviste son durum: $(Get-InvoiceStatus $n2)"
    Show-Deliveries $n2
}

# ---------------------------------------------------------------------------------------------------------------------
Write-Line ''
Write-Line '3) ERP''ye hiç gitmemiş bir faturanın iptalinde ERP''de oluşan kayıtlar ve faturanın son durumu'
Set-Erp @{ ServerError = 100 }
$n3b = New-Invoice
Wait-Until { (Get-Outbox $n3b 'Gönderim') -match '^Bekliyor\|[1-9]' } 60 'Tekrar denemedeki fatura: ilk deneme 500 aldı'
$c = Request-Cancel $n3b
Check ($c.Status -eq 202) "Tekrar denemedeki faturanın iptali: HTTP $($c.Status)"
Wait-Until { (Get-InvoiceStatus $n3b) -eq 'İptal Edildi' } 90 'Fatura İptal Edildi oldu'
Check ((Get-SqlScalar "SELECT count(*) FROM invoices WHERE invoice_number = '$n3b'") -eq '0') 'ERP''de fatura kaydı: 0'
Check ((Get-SqlScalar "SELECT count(*) FROM cancellations WHERE invoice_number = '$n3b'") -eq '0') 'ERP''de iptal kaydı: 0'
Show-Invoice $n3b
$n3 = New-Invoice
Wait-Until { (Get-InvoiceStatus $n3) -eq 'Başarısız' } 480 'Başarısız biten fatura: ERP 500 dönerken bütün denemeler bitti'
$c = Request-Cancel $n3
Check ($c.Status -eq 202) "Başarısız faturanın iptali: HTTP $($c.Status)"
Wait-Until { (Get-InvoiceStatus $n3) -eq 'İptal Edildi' } 60 'Fatura İptal Edildi oldu'
Check ((Get-SqlScalar "SELECT count(*) FROM invoices WHERE invoice_number = '$n3'") -eq '0') 'ERP''de fatura kaydı: 0'
Check ((Get-SqlScalar "SELECT count(*) FROM cancellations WHERE invoice_number = '$n3'") -eq '0') 'ERP''de iptal kaydı: 0'
Show-Invoice $n3
$details = (Send-Api GET "/api/v1/invoices/$n3/details" (Get-UserToken 'operator')).Json
Write-Line "  Operatörün ayrıntıda gördüğü: fatura $($details.invoice.status), iptal $($details.cancellation.status)"

# ---------------------------------------------------------------------------------------------------------------------
Write-Line ''
Write-Line '4) Onay haberinden önce gelen iptal haberi ve iki kez gelen iptal haberi faturayı tutarlı biçimde İptal Edildi yapıyor'
Write-Line '  a) Elle imzalanmış haberler (simülatörün haberleri kapalı)'
Set-Erp @{ Success = 100 } @{ 'Webhooks__Enabled' = 'false' }
Remove-Item 'Env:Webhooks__Enabled' -ErrorAction SilentlyContinue
$n4 = New-Invoice
Wait-Until { (Get-InvoiceStatus $n4) -eq 'Gönderildi' } 60 "$n4 Gönderildi oldu"
$reference = Invoke-InvoiceSql "SELECT erp_reference FROM invoices WHERE invoice_number = '$n4'"
$id = "gun23-$(Get-Random)"
$r = Send-SignedEvent "$id-cancel" 'invoice.cancelled' $n4 $reference
Write-Line "    İptal haberi: HTTP $($r.Status), fatura $(Get-InvoiceStatus $n4)"
$r = Send-SignedEvent "$id-cancel" 'invoice.cancelled' $n4 $reference
Write-Line "    Aynı iptal haberi ikinci kez: HTTP $($r.Status), fatura $(Get-InvoiceStatus $n4)"
$r = Send-SignedEvent "$id-approved" 'invoice.approved' $n4 $reference
Write-Line "    Onay haberi: HTTP $($r.Status), fatura $(Get-InvoiceStatus $n4)"
Check ((Get-InvoiceStatus $n4) -eq 'İptal Edildi') "Son durum: $(Get-InvoiceStatus $n4)"
Show-Events $n4
Write-Line '  b) Simülatörün kendi davranışı (sıra karışması ve çift gönderme yüzde 100)'
Set-Erp @{ Success = 100 } @{ 'Webhooks__FirstEventMinSeconds' = 15; 'Webhooks__FirstEventMaxSeconds' = 15; 'Webhooks__SecondEventMinSeconds' = 15
    'Webhooks__SecondEventMaxSeconds' = 15; 'Webhooks__Problems__OrderMixRate' = 100; 'Webhooks__Problems__DuplicateRate' = 100 }
$n5 = New-Invoice
Wait-Until { (Get-InvoiceStatus $n5) -eq 'Gönderildi' } 30 "$n5 Gönderildi oldu"
$c = Request-Cancel $n5
Check ($c.Status -eq 202) "İptal isteği: HTTP $($c.Status)"
Wait-Until { (Invoke-InvoiceSql "SELECT count(*) FROM erp_webhook_events WHERE invoice_number = '$n5' AND event_type = 'invoice.approved'") -eq '1' } 90 'Onay haberi de geldi'
$order = Invoke-InvoiceSql ("SELECT (SELECT received_at FROM erp_webhook_events WHERE invoice_number = '$n5' AND event_type = 'invoice.cancelled') < " +
    "(SELECT received_at FROM erp_webhook_events WHERE invoice_number = '$n5' AND event_type = 'invoice.approved')")
Check ($order -eq 't') "İptal haberi onay haberinden önce geldi: $order"
Wait-Until { [int](Invoke-InvoiceSql "SELECT delivery_count FROM erp_webhook_events WHERE invoice_number = '$n5' AND event_type = 'invoice.cancelled'") -eq 2 } 30 'İptal haberi ikinci kez geldi'
Check ((Get-InvoiceStatus $n5) -eq 'İptal Edildi') "Son durum: $(Get-InvoiceStatus $n5)"
$decision = Get-ErpDecision $n5
Check ($decision -eq 'cancelled') "ERP'nin GET cevabındaki karar: $decision"
Show-Events $n5
Show-Deliveries $n5

# ---------------------------------------------------------------------------------------------------------------------
Write-Line ''
Write-Line '5) İptal haberi hiç gelmediğinde mutabakat farkı buluyor ve faturayı İptal Edildi yapıyor'
Set-Erp @{ Success = 100 } @{ 'Webhooks__Problems__LostDecisionRate' = 100 }
$n6 = New-Invoice
Wait-Until { (Get-InvoiceStatus $n6) -eq 'İşleme Alındı' } 60 "$n6 İşleme Alındı oldu"
$c = Request-Cancel $n6
Check ($c.Status -eq 202) "İptal isteği: HTTP $($c.Status)"
Wait-Until { (Get-Outbox $n6 'İptal') -like 'Tamamlandı|*' } 60 'İptal ERP''ye ulaştı, satır Tamamlandı oldu'
Start-Sleep -Seconds 15
Check ((Get-InvoiceStatus $n6) -eq 'İşleme Alındı') "15 sn sonra, haber gelmedi: fatura $(Get-InvoiceStatus $n6)"
Show-Deliveries $n6
$state = Invoke-Reconciliation
Check ($state.status -eq 'Tamamlandı') "Mutabakat $($state.id): $($state.status), kontrol edilen $($state.checkedCount), düzeltilen $($state.fixedCount), raporlanan $($state.reportedCount)"
Show-Rows 'Servis (reconciliation_findings):' "SELECT finding_type, action, details FROM reconciliation_findings WHERE invoice_number = '$n6' ORDER BY id"
Check ((Get-InvoiceStatus $n6) -eq 'İptal Edildi') "Son durum: $(Get-InvoiceStatus $n6)"

Set-Erp @{ Success = 100 }
Save-Report
