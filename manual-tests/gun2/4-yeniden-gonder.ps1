# Gün 2 - Madde 4: 3. maddede Başarısız kalan bütün faturaları resend ile bir kez tekrar gönder,
# sonra karşılaştırmayı yeniden çalıştır (simülatörde birden fazla kaydı olan fatura sayısı dahil).
# Simülatör yeniden başlatılmaz: seed'li dizi 3. maddenin kaldığı yerden devam eder.
param([string]$From, [string]$To)
. "$PSScriptRoot\_common.ps1"

if (-not $From -or -not $To) {
    $range = Read-Range 'gun2-3'
    if (-not $range) { throw 'Önce .\manual-tests\gun2\3-varsayilan.ps1 çalıştırın (ya da -From / -To verin).' }
    $From = $range.From; $To = $range.To
}

Write-Title "4) $From .. $To aralığında Başarısız faturalar bir kez yeniden gönderiliyor"
Wait-Service

$failed = @(Get-ServiceRows ("SELECT invoice_number FROM invoices WHERE invoice_number BETWEEN '$From' AND '$To' " +
    "AND status = 'Başarısız' ORDER BY invoice_number;"))
Write-Step "$($failed.Count) Başarısız fatura yeniden gönderiliyor (POST .../resend)"
$results = @(foreach ($number in $failed) { $r = Send-ServiceResend $number; Write-ServiceResult $r; $r })

Write-Step 'Simülatörün seçtiği davranış, ilk -> ikinci gönderim => servisteki son durum (simülatör logundan)'
$behaviors = Get-SimulatorBehaviors
$results | Group-Object { ($behaviors[$_.InvoiceNumber] -join ' -> ') + ' => ' + $_.Status } |
    Sort-Object Count -Descending | ForEach-Object { Write-Host ('  {0,-52} {1,4}' -f $_.Name, $_.Count) }

Write-Step "Karşılaştırma ($From .. $To)"
$c = Compare-Invoices -From $From -To $To

$allResent = $results.Count -eq $failed.Count -and @($results | Where-Object HttpStatus -ne 200).Count -eq 0
Write-Result $allResent ("$($failed.Count) fatura yeniden gönderildi; Gönderildi+var: $($c.SentFound), " +
    "Başarısız+yok: $($c.FailedMissing), Başarısız+var: $($c.FailedFound), birden fazla kayıt: $($c.MultipleRecords)")
