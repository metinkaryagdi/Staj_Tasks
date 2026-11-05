# 3-felaket.ps1 bittikten sonra, stack ayaktayken: koşunun ilk 202 süresi, saat farkı, kaybolan iptallerin ayrımı, k6 sayısıyla karşılaştırma
# ve servisteki son durumun ERP'nin kararıyla karşılaştırılması. Yalnız okur. Çıktı manual-tests\output\gun24\c-felaket-ek.txt.
#   .\manual-tests\gun24\4-felaket-ek-olcum.ps1 -RunId GUN24-FELAKET-... -DeletedAt 2026-11-05T07:36:03.237Z
param([Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$DeletedAt, [string]$Name = 'felaket', [string]$Etiket = 'c-felaket-ek')
. "$PSScriptRoot\_common.ps1"
Use-Gun10Volumes "gun24-$Name"
[void](Use-BackupFolder "$Name-yedek")
New-Report $Etiket
Write-Title 'Felaket koşusu: ek ölçüm (yalnız okur)'

$dbNow = [DateTimeOffset]((Invoke-InvoiceSql "SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.MS') || '+00:00'"))
$diff = ([DateTimeOffset]::UtcNow - $dbNow).TotalSeconds
Write-Line ("Bilgisayar ile veritabanı saati farkı: {0:0.0} sn" -f $diff)

$first = [DateTimeOffset](Invoke-InvoiceSql "SELECT to_char(min(created_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.MS') || '+00:00' FROM invoices WHERE created_at > '$DeletedAt'")
$deleted = [DateTimeOffset]$DeletedAt
Write-Line ("Silme {0:o}; dönüşten sonra ilk fatura {1:o}; silmeden ilk 202'ye {2:0.0} sn" -f $deleted, $first, ($first - $deleted).TotalSeconds)

$log = Get-Content (Join-Path $OutputDir "$Name-servis-logu.txt") -Encoding UTF8
$accepted = [Collections.Generic.HashSet[string]]::new(); $cancels = [Collections.Generic.HashSet[string]]::new()
foreach ($line in $log) {
    if ($line -match 'Invoice queued invoice=(FTR-\d+)') { [void]$accepted.Add($Matches[1]) }
    elseif ($line -match 'Invoice cancellation queued invoice=(FTR-\d+)') { [void]$cancels.Add($Matches[1]) }
}
$inBackup = Get-RowSet (Invoke-InvoiceSql "SELECT invoice_number FROM invoices WHERE created_at < '$DeletedAt'")
$cancelInBackup = Get-RowSet (Invoke-InvoiceSql "SELECT invoice_number FROM erp_outbox WHERE kind = 'İptal' AND created_at < '$DeletedAt'")
$erpAll = Get-RowSet (Get-SqlScalar "SELECT invoice_number FROM invoices WHERE customer_code = '$RunId'")
$erpCancelled = Get-RowSet (Get-SqlScalar "SELECT c.invoice_number FROM cancellations c JOIN invoices i ON i.invoice_number = c.invoice_number WHERE i.customer_code = '$RunId'")

$k6 = Get-Content (Join-Path $RepoRoot "load-test\results\$RunId.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$runBefore = @($accepted | Where-Object { $_ }).Count - [int](Invoke-InvoiceSql "SELECT count(*) FROM invoices WHERE customer_code <> '$RunId' AND created_at < '$DeletedAt'")
$runAfter = [int](Invoke-InvoiceSql "SELECT count(*) FROM invoices WHERE customer_code = '$RunId' AND created_at >= '$DeletedAt'")
Write-Line "k6 kabul $($k6.accepted); silmeden önce servis logunda $runBefore + dönüşten sonra veritabanında $runAfter = $($runBefore + $runAfter)"
Check (($runBefore + $runAfter) -eq $k6.accepted) "k6'nın 202 aldığı her fatura sayıldı"

$lost = @($cancels | Where-Object { -not $cancelInBackup.Contains($_) -and -not $erpCancelled.Contains($_) })
$lostBackupErp = @($lost | Where-Object { $inBackup.Contains($_) -and $erpAll.Contains($_) }).Count
$lostBackupNoErp = @($lost | Where-Object { $inBackup.Contains($_) -and -not $erpAll.Contains($_) }).Count
$lostAtErp = @($lost | Where-Object { -not $inBackup.Contains($_) -and $erpAll.Contains($_) }).Count
$lostNowhere = @($lost | Where-Object { -not $inBackup.Contains($_) -and -not $erpAll.Contains($_) }).Count
Write-Line "Kaybolan $($lost.Count) iptal isteği:"
Write-Line "  Faturası yedekte, ERP'de iptalsiz: $lostBackupErp"
Write-Line "  Faturası yedekte, ERP'de yok: $lostBackupNoErp"
Write-Line "  Faturası yedekte yok, ERP'de iptalsiz (Serviste Yok): $lostAtErp"
Write-Line "  Fatura da kayıp, hiçbir yerde yok: $lostNowhere"

# ERP kararıyla son durum: karar haberleri (kayıp olanlar dahil) ve iptaller; yalnız serviste olan faturalar.
$decision = @{}
foreach ($row in ((Get-SqlScalar "SELECT DISTINCT d.invoice_number || '|' || d.event_type FROM webhook_deliveries d JOIN invoices i ON i.id = d.invoice_id WHERE i.customer_code = '$RunId' AND d.kind IN ('Normal', 'LostDecision') AND d.event_type IN ('invoice.approved', 'invoice.rejected') AND d.status <> 'Skipped' OR (i.customer_code = '$RunId' AND d.kind = 'LostDecision')") -split "`r?`n")) { $p = $row -split '\|'; if ($p.Count -eq 2) { $decision[$p[0]] = $p[1] } }
$rows = (Invoke-InvoiceSql "SELECT invoice_number || '|' || status FROM invoices WHERE customer_code = '$RunId'") -split "`r?`n"
$cancelMismatch = 0; $decisionMismatch = 0
foreach ($row in $rows) {
    $p = $row -split '\|'; if ($p.Count -ne 2) { continue }
    if ($erpCancelled.Contains($p[0]) -and $p[1] -ne 'İptal Edildi') { $cancelMismatch++ }
    if ($decision[$p[0]] -eq 'invoice.approved' -and $p[1] -eq 'Reddedildi') { $decisionMismatch++ }
    if ($decision[$p[0]] -eq 'invoice.rejected' -and $p[1] -eq 'Onaylandı') { $decisionMismatch++ }
}
Check ($cancelMismatch -eq 0) "ERP'de iptal edilip serviste İptal Edildi olmayan: $cancelMismatch"
Check ($decisionMismatch -eq 0) "Servisteki son durumu ERP'nin onay/red haberiyle çelişen: $decisionMismatch ($($decision.Count) kararlı fatura)"
Save-Report
