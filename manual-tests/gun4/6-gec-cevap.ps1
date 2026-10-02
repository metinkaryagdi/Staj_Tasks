# Gün 4 - Kontrol listesi 6: simülatörde geç cevap %100 iken 10 fatura. ~1,5 dk.
#   İlk haberlerin, servis faturayı Gönderildi yapmadan önce geldiği loglarla gösterilir; sonunda hepsi Onaylandı ya da Reddedildi.
# Simülatör kaydı hemen yapıp 30 sn geç cevap veriyor; servis 10 sn'de vazgeçip tekrar denemede simülatöre sorar, bulur ve
# Gönderildi yapar (~12 sn). invoice.received kayıttan 2-10 sn sonra gelir: o sırada fatura servis için hâlâ Bekliyor.
# Haber sorunları 0: "sonunda hepsi kesin durumda" ancak karar kaybolmazsa mümkün.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: $_ - simülatör varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Restart-Simulator } catch { }; break }

Write-Title 'Kontrol listesi 6) Simülatörde geç cevap %100, 10 fatura'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
Restart-Simulator (Get-SimSettings -Behavior 'LateResponse')
$since = [datetime]::UtcNow.AddSeconds(-1)
$numbers = New-Invoices 10
$list = InList $numbers
$seconds = Wait-InvoicesIn $numbers @('Onaylandı', 'Reddedildi') 180 'kesin durumda'
Write-Host "  10 fatura $seconds sn'de kesin durumda"
Wait-EventsDone $numbers | Out-Null

Write-Host ''
Write-Host '  Servis logu (fatura başına, zaman sırasıyla): haber "stored ... status=Bekliyor invoiceStatus=Bekliyor" -> outbox "outcome=Sent" -> "applied-after-send"' -ForegroundColor Cyan
$log = @(Get-ServiceLog | Where-Object { $_ -match 'ERP webhook (stored|applied-after-send)|ERP send invoice=' })
$early = 0
foreach ($n in $numbers) {
    $lines = @($log | Where-Object { $_ -match " invoice=$n " })
    Write-Host "  --- $n" -ForegroundColor DarkGray
    $lines | ForEach-Object { Write-Host "  $($_.Substring(0, [Math]::Min(230, $_.Length)))" -ForegroundColor DarkGray }
    $waiting = @($lines | Where-Object { $_ -match 'webhook stored .*status=Bekliyor invoiceStatus=Bekliyor->Bekliyor' })
    $applied = @($lines | Where-Object { $_ -match 'webhook applied-after-send .*invoiceStatus=Gönderildi->' })
    if ($waiting.Count -ge 1 -and $applied.Count -ge 1) { $early++ }
}

Write-DbHeader 'Veritabanı: ilk haberin servise geldiği an < faturanın Gönderildi olduğu an (erp_outbox.processed_at)'
$sql = "SELECT o.invoice_number, to_char(min(e.received_at), 'HH24:MI:SS.MS') AS ilk_haber_geldi, to_char(o.processed_at, 'HH24:MI:SS.MS') AS gonderildi_oldu, " +
       "round(EXTRACT(EPOCH FROM o.processed_at - min(e.received_at))::numeric, 3) AS fark_sn FROM erp_outbox o JOIN erp_webhook_events e ON e.invoice_number = o.invoice_number " +
       "WHERE o.invoice_number IN ($list) GROUP BY o.invoice_number, o.processed_at ORDER BY 1"
Show-ServiceQuery "$sql;"
$dbEarly = Count-Service "SELECT count(*) FROM ($sql) x WHERE fark_sn > 0;"
$final = Count-Service "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status IN ('Onaylandı', 'Reddedildi');"
$late = @(Get-SimulatorLog | Where-Object { $_ -match 'behavior=LateResponse' } | Where-Object { $line = $_; @($numbers | Where-Object { $line -match "invoice=$_ " }).Count -gt 0 }).Count

Check (Write-DbVerdict 'simülatör 10 faturanın hepsine geç cevap verdi' "$late" ($late -ge 10))
Check (Write-DbVerdict '10 faturanın hepsinde ilk haber Gönderildi''den önce geldi (log ve veritabanı)' "log $early, veritabanı $dbEarly" ($early -eq 10 -and $dbEarly -eq 10))
Check (Write-DbVerdict '10 fatura Onaylandı ya da Reddedildi' "$final" ($final -eq 10))

Restart-Simulator
Write-Result $allPassed 'ilk haberler fatura Gönderildi olmadan geldi, bekletildi, Gönderildi olunca işlendi; hepsi kesin durumda'
