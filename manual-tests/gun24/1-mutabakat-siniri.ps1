# Kontrol listesi 1: mutabakatın eski faturalar için ERP'ye sorduğu sayı. Satırlar iki veritabanına doğrudan yazılır (pencereden eski,
# iki tarafta da Onaylandı); ERP'de iptal edilmiş ama haberi hiç gelmemiş üç fatura bunların arasındadır. Her çalışmanın sorgu sayısı
# servis logundaki özetten okunur. Tek cevabın alınamaması bu script'te değil, ReconciliationLimitTests'te sınanır: simülatörün GET
# ucu hata üretmez. Çıktı manual-tests\output\gun24\a-mutabakat-siniri.txt. Boş volume ister. ~25 dk.
#   .\manual-tests\gun24\1-mutabakat-siniri.ps1
param([string]$Etiket = 'a-mutabakat-siniri', [int]$First = 20000, [int]$Second = 200000)
. "$PSScriptRoot\_common.ps1"
Use-Gun10Volumes 'gun24-mutabakat'
[void](Use-BackupFolder 'yedek-diger')

New-Report $Etiket
Write-Title 'Mutabakat: eski fatura sayısı arttıkça ERP''ye sorulan sayı, kaybolan iptal haberi'
Write-Line "Koşu: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Start-Stack
Restart-Simulator
$limit = (Get-Content (Join-Path $RepoRoot 'invoice-service\src\InvoiceService.Api\appsettings.json') -Raw -Encoding UTF8) -replace '(?s).*"MaxErpLookupsPerRun":\s*(\d+).*', '$1'
Write-Line "MaxErpLookupsPerRun: $limit"

function Add-OldInvoices([int]$From, [int]$To) {
    [void](Invoke-InvoiceSql ("INSERT INTO invoices (invoice_number, customer_code, amount, currency, invoice_date, status, erp_reference, send_attempt_count, created_at, updated_at) " +
        "SELECT 'ESKI-' || lpad(n::text, 6, '0'), 'C-ESKI', 125.50, 'TRY', DATE '2026-01-01', 'Onaylandı', 'E-' || n, 1, now() - interval '30 days' + n * interval '1 second', now() - interval '30 days' FROM generate_series($From, $To) n"))
    [void](Get-SqlScalar ("INSERT INTO invoices (invoice_number, erp_reference, customer_code, amount, currency, invoice_date, received_at, behavior, request_sequence) " +
        "SELECT 'ESKI-' || lpad(n::text, 6, '0'), 'E-' || n, 'C-ESKI', 125.50, 'TRY', DATE '2026-01-01', now() - interval '30 days', 'Success', n FROM generate_series($From, $To) n"))
}
function Lose-Cancellation([string]$Number) {
    [void](Get-SqlScalar "INSERT INTO cancellations (invoice_number, cancelled_at) VALUES ('$Number', now() - interval '2 days')")
}
function Get-Status([string]$Number) { Invoke-InvoiceSql "SELECT status FROM invoices WHERE invoice_number = '$Number'" }
function Run-One {
    $state = Invoke-ReconciliationRetry
    Start-Sleep -Seconds 1
    $line = Get-LookupLine $state.id
    $seconds = ([DateTimeOffset]$state.finishedAt - [DateTimeOffset]$state.startedAt).TotalSeconds
    Write-Line ("  Çalışma {0}: {1}, ERP'ye sorulan {2}, cevapsız {3}, karşılaştırılan {4}, düzeltilen {5}, {6:0.0} sn" -f
        $state.id, $state.status, $line.Asked, $line.Unanswered, $state.checkedCount, $state.fixedCount, $seconds)
    Check ($state.status -eq 'Tamamlandı' -and $line.Asked -le [int]$limit) "Sorulan sayı sınırı aşmadı ($($line.Asked) <= $limit)"
    $state
}

Write-Line ''
Write-Line "1) $First eski fatura; iki kayıp iptal haberi: biri ilk çalışmanın, biri ikinci çalışmanın sırasında"
Add-OldInvoices 1 $First
Lose-Cancellation 'ESKI-000010'
Lose-Cancellation 'ESKI-015000'
[void](Run-One)
Check ((Get-Status 'ESKI-000010') -eq 'İptal Edildi') "ESKI-000010 ilk çalışmada: $(Get-Status 'ESKI-000010')"
Check ((Get-Status 'ESKI-015000') -eq 'Onaylandı') "ESKI-015000 henüz sırası gelmedi: $(Get-Status 'ESKI-015000')"
[void](Run-One)
Check ((Get-Status 'ESKI-015000') -eq 'İptal Edildi') "ESKI-015000 ikinci çalışmada: $(Get-Status 'ESKI-015000')"

Write-Line ''
Write-Line "2) $Second eski fatura; kayıp iptal haberi turun sonuna yakın"
Add-OldInvoices ($First + 1) $Second
$last = 'ESKI-{0:000000}' -f ($Second - 100)
Lose-Cancellation $last
$runs = 0
do { [void](Run-One); $runs++ } while ((Get-Status $last) -ne 'İptal Edildi' -and $runs -lt 25)
Check ((Get-Status $last) -eq 'İptal Edildi') "$last bu bölümün $runs. çalışmasında yakalandı: $(Get-Status $last)"

Write-Line ''
Write-Line '3) Son durum'
Show-Rows 'Bulgular:' "SELECT finding_type, action, count(*) FROM reconciliation_findings GROUP BY 1, 2 ORDER BY 1, 2"
Show-Rows 'Eski faturaların durumu:' "SELECT status, count(*) FROM invoices WHERE customer_code = 'C-ESKI' GROUP BY 1 ORDER BY 1"
Save-Report
