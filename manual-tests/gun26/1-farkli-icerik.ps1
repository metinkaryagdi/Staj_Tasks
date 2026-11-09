# Kontrol listesi 1: yeni sürümde aynı numara ERP'de farklı içerikle kayıtlıysa fatura kabul edilmiş sayılmaz, Başarısız olup
# operatörün önüne düşer. Üç yol: v2'nin 202 cevabı (ilk gönderim), sonraki denemenin ERP'ye sorması, operatörün yeniden göndermesi.
# Boş veritabanıyla başlar; simülatör hatasız (Success 100), yüzde 100 v2. Çıktı manual-tests\output\gun26\a1-farkli-icerik.txt.
#   .\manual-tests\gun26\1-farkli-icerik.ps1
. "$PSScriptRoot\_common.ps1"
Use-Gun10Volumes "gun26-farkli-$(Get-Date -Format 'MMddHHmm')"
New-Report 'a1-farkli-icerik'
Write-Title 'Yeni sürümde farklı içerikle kayıtlı numara'
Write-Line "Koşu: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Start-Stack
$since = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
Set-Erp @{ Success = 100 }
Set-V2Percent 100

$body = '{"customerCode":"C-026","amount":125.50,"currency":"TRY","invoiceDate":"2026-11-09"}'
function New-Invoice26 {
    $r = Send-Api POST '/api/v1/invoices' (Get-OrderSystemToken) $body
    if ($r.Status -ne 202) { throw "Fatura oluşturulamadı: HTTP $($r.Status) $($r.Body)" }
    $r.Json.invoiceNumber
}
# Aynı numara ERP'de başka içerikle (tutar 999.00, tarih 2026-11-08), doğrudan v2'ye.
function Register-Other([string]$Number) {
    $r = Send-Erp POST '/api/v2/invoices' "{`"invoiceNumber`":`"$Number`",`"customerCode`":`"C-026`",`"amountKurus`":99900,`"currency`":`"TRY`",`"invoiceDate`":`"2026-11-08`"}"
    Write-Line "  ERP'ye doğrudan v2 ile $Number (tutar 999.00, tarih 2026-11-08): HTTP $($r.Status) $($r.Json.erpReference)"
    $r.Json.erpReference
}
$errorSql = { param($n) Invoke-InvoiceSql "SELECT status || '|' || coalesce(erp_reference, '-') || '|' || coalesce(last_error, '') FROM invoices WHERE invoice_number = '$n'" }

Write-Line ''
Write-Line '1) İlk gönderim: v2 aynı numaraya 202 ile mevcut kaydı döner'
$first = 'FTR-000001'
Check ((Invoke-InvoiceSql 'SELECT count(*) FROM invoices') -eq '0') 'Veritabanı boş: ilk faturanın numarası FTR-000001 olacak'
[void](Register-Other $first)
$n1 = New-Invoice26
Check ($n1 -eq $first) "Servisin verdiği numara: $n1"
Wait-Until { (Get-InvoiceStatus $n1) -eq 'Başarısız' } 60 "$n1 Başarısız"
$row = (& $errorSql $n1) -split '\|', 3
Check ($row[0] -eq 'Başarısız' -and $row[1] -eq '-') "Durum $($row[0]), erp_reference $($row[1])"
Check ($row[2] -like "*farklı içerikle kayıtlı*") "Son hata: $($row[2])"
Check ((Get-SqlScalar "SELECT count(*) FROM invoices WHERE invoice_number = '$n1'") -eq '1') "ERP'de $n1 kaydı: 1 (yeni kayıt açılmadı)"
Show-Invoice $n1

Write-Line ''
Write-Line '2) Sonraki deneme: ilk POST ERP''ye ulaşamaz, ERP''de kayıt sonra oluşur, servis ERP''ye sorup bulur'
Push-Location $RepoRoot
try { docker compose stop erp-simulator 2>&1 | Out-Null } finally { Pop-Location }
Write-Line '  Simülatör durduruldu'
$n2 = New-Invoice26
# Bir sonraki deneme en az 25 sn uzaktayken simülatör açılır ve kayıt oluşturulur; servisin denemesi ondan sonra gelir.
Wait-Until { [int](Invoke-InvoiceSql "SELECT coalesce(extract(epoch FROM next_attempt_at - now()), 0)::int FROM erp_outbox WHERE invoice_number = '$n2' AND kind = 'Gönderim' AND status = 'Bekliyor'") -ge 25 } 300 "$n2 sonraki denemesi 25 sn'den uzak"
Write-Line "  Şu ana kadarki deneme: $(Invoke-InvoiceSql "SELECT send_attempt_count FROM invoices WHERE invoice_number = '$n2'")"
Push-Location $RepoRoot
try { docker compose start erp-simulator 2>&1 | Out-Null } finally { Pop-Location }
Wait-Until { try { (Send-Erp GET '/health').Status -eq 200 } catch { $false } } 60 'Simülatör hazır'
[void](Register-Other $n2)
Wait-Until { (Get-InvoiceStatus $n2) -eq 'Başarısız' } 120 "$n2 Başarısız"
$row = (& $errorSql $n2) -split '\|', 3
Check ($row[0] -eq 'Başarısız' -and $row[1] -eq '-') "Durum $($row[0]), erp_reference $($row[1])"
Check ($row[2] -like "*farklı içerikle kayıtlı*") "Son hata: $($row[2])"
Push-Location $RepoRoot
try { $line = @(docker compose logs --no-color --no-log-prefix --since $since invoice-service 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match $n2 -and $_ -match 'check=found' }) | Select-Object -Last 1 }
finally { Pop-Location }
Check ([bool]$line) "Servis logunda ERP'ye sorulup bulunduğu deneme (check=found): $(if ($line) { $line.Substring(0, [Math]::Min(200, $line.Length)) })"
Show-Invoice $n2

Write-Line ''
Write-Line '3) Operatör yeniden gönderir: ERP''ye sorulur, kayıt yine farklı, fatura yine Başarısız'
$attemptsBefore = [int](Invoke-InvoiceSql "SELECT send_attempt_count FROM invoices WHERE invoice_number = '$n2'")
$resend = Send-Api POST "/api/v1/invoices/$n2/resend" (Get-UserToken 'operator')
Write-Line "  POST /api/v1/invoices/$n2/resend: HTTP $($resend.Status)"
Wait-Until { [int](Invoke-InvoiceSql "SELECT send_attempt_count FROM invoices WHERE invoice_number = '$n2'") -gt $attemptsBefore -and (Invoke-InvoiceSql "SELECT status FROM erp_outbox WHERE invoice_number = '$n2' AND kind = 'Gönderim'") -eq 'Başarısız' } 120 "$n2 yeniden denendi ve Başarısız"
$row = (& $errorSql $n2) -split '\|', 3
Check ($row[0] -eq 'Başarısız' -and $row[1] -eq '-') "Durum $($row[0]), erp_reference $($row[1]), deneme $attemptsBefore -> $(Invoke-InvoiceSql "SELECT send_attempt_count FROM invoices WHERE invoice_number = '$n2'")"
Push-Location $RepoRoot
try { $found = @(docker compose logs --no-color --no-log-prefix --since $since invoice-service 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match "invoice=$n2 " -and $_ -match 'check=found outcome=Failed' }) }
finally { Pop-Location }
Check ($found.Count -ge 2) "Servis logunda $n2 için ERP'ye sorulup farklı bulunan deneme: $($found.Count) (yeniden göndermeden önce ve sonra)"
Show-Rows 'operator_actions:' "SELECT operator_name, action, result FROM operator_actions WHERE invoice_number = '$n2' ORDER BY id"
Check ((Get-SqlScalar "SELECT count(*) FROM invoices WHERE invoice_number = '$n2'") -eq '1') "ERP'de $n2 kaydı: 1 (yeniden gönderme yeni kayıt açmadı)"

Write-Line ''
Write-Line '4) Operatör iptal eder: ERP''deki kayıt bu faturanın değil, iptal ERP''ye gönderilmez'
$cancel = Request-Cancel $n2
Write-Line "  POST /api/v1/invoices/$n2/cancel: HTTP $($cancel.Status)"
Wait-Until { (Invoke-InvoiceSql "SELECT status FROM erp_outbox WHERE invoice_number = '$n2' AND kind = 'İptal'") -eq 'Başarısız' } 120 "$n2 iptal satırı Başarısız"
$cancelError = Invoke-InvoiceSql "SELECT last_error FROM erp_outbox WHERE invoice_number = '$n2' AND kind = 'İptal'"
Check ($cancelError -like '*farklı içerikle kayıtlı*') "İptal satırının son hatası: $cancelError"
Check ((Get-InvoiceStatus $n2) -eq 'Başarısız') "Fatura değişmedi: $(Get-InvoiceStatus $n2)"
Check ((Get-SqlScalar "SELECT count(*) FROM cancellations WHERE invoice_number = '$n2'") -eq '0') "ERP'de $n2 için iptal kaydı: 0"
Show-Rows 'Servis (erp_outbox):' "SELECT $OutboxColumns FROM erp_outbox WHERE invoice_number = '$n2' ORDER BY id"

Write-Line ''
Write-Line '5) ERP kendi kaydını iptal eder: haber gelir, fatura bu kaydın sahibi olmadığı için değişmez'
$erpCancel = Send-Erp POST "/api/v2/invoices/$n2/cancel"
Write-Line "  ERP'de doğrudan iptal (kaydın sahibi): HTTP $($erpCancel.Status) $($erpCancel.Json.cancelReference)"
Wait-Until { [int](Invoke-InvoiceSql "SELECT count(*) FROM erp_webhook_events WHERE invoice_number = '$n2' AND event_type = 'invoice.cancelled'") -ge 1 } 120 "$n2 iptal haberi servise ulaştı"
$row = (& $errorSql $n2) -split '\|', 3
Check ($row[0] -eq 'Başarısız' -and $row[1] -eq '-') "Fatura değişmedi: durum $($row[0]), erp_reference $($row[1])"
Check ($row[2] -like '*farklı içerikle kayıtlı*') "Son hata duruyor: $($row[2])"
Show-Events $n2

Write-Line ''
Write-Line '6) Operatörün önünde: operasyon ekranının kullandığı liste, Başarısız süzgeciyle'
$list = Send-Api GET "/api/v1/invoices?status=$([Uri]::EscapeDataString('Başarısız'))&pageSize=50" (Get-UserToken 'operator')
$numbers = @($list.Json.items | ForEach-Object { $_.invoiceNumber })
Check ($list.Status -eq 200 -and $numbers -contains $n1 -and $numbers -contains $n2) "GET /api/v1/invoices?status=Başarısız: HTTP $($list.Status), listede $($numbers -join ', ')"

Write-Line ''
Write-Line '7) Mutabakat bu faturaları kabul edilmiş saymaz (ERP''deki iptal de uygulanmaz)'
$run = Invoke-ReconciliationRetry
Write-Line "  Mutabakat $($run.id): $($run.status), düzeltilen $($run.fixedCount), raporlanan $($run.reportedCount)"
Show-Rows 'Bulgular:' "SELECT invoice_number, finding_type, action, left(details, 110) AS ayrinti FROM reconciliation_findings WHERE run_id = $($run.id) ORDER BY invoice_number"
Check ((Invoke-InvoiceSql "SELECT count(*) FROM invoices WHERE invoice_number IN ('$n1','$n2') AND status = 'Başarısız' AND erp_reference IS NULL") -eq '2') 'Mutabakattan sonra iki fatura da Başarısız, erp_reference yok'
Check ((Invoke-InvoiceSql "SELECT count(*) FROM reconciliation_findings WHERE invoice_number = '$n2' AND finding_type = 'ERP İptal Etmiş'") -eq '0') "$n2 için ERP İptal Etmiş bulgusu: 0"

Save-Report
