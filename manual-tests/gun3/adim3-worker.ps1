# Gün 3 - Adım 3: arka plan worker'ı (kontrol listesinin parçası değil, adımın kendi testi).
# Bu adımda her fatura tek kez denenir: 202 -> Gönderildi / Tamamlandı, başka her sonuç -> Başarısız. Tekrar deneme Adım 4'te.
#
#   A) Success %100, 20 fatura: worker kuyruğu boşaltıyor; hepsi Gönderildi, outbox Tamamlandı, 1 deneme, kilit temizlenmiş,
#      simülatörde her faturadan tam bir kayıt ve erp_reference iki tarafta aynı.
#   B) LateResponse %100 (simülatör 30 sn bekletir, servis 10 sn'de vazgeçer), 25 fatura: her gönderim 10 sn sürdüğü için
#      aynı anda kaç gönderim yapıldığı simülatörün kayıt saatlerinden görülür: en fazla 10 (ayar dosyasındaki
#      Outbox:MaxConcurrentSends), yani 10 + 10 + 5'lik dalgalar.
. "$PSScriptRoot\_common.ps1"

Write-Title 'Adım 3) Arka plan worker''ı: kuyruğu boşaltıyor, aynı anda en fazla 10 gönderim'

Write-Step 'Fatura Servisi yeni kodla derlenip yeniden başlatılıyor...'
Invoke-Compose @('up', '-d', '--build', 'invoice-service')
Wait-Service
$settingsLine = Get-ServiceLog | Where-Object { $_ -match 'ERP settings:' } | Select-Object -Last 1
Write-Host "  $($settingsLine -replace '^.*ERP settings:', 'Servis ayarları:')" -ForegroundColor DarkGray

$allPassed = $true

# --- A) Success %100 ---------------------------------------------------------------------------------------------
Restart-Simulator @{
    Simulator__Rates__Success       = 100
    Simulator__Rates__Busy          = 0
    Simulator__Rates__ServerError   = 0
    Simulator__Rates__SaveThenError = 0
    Simulator__Rates__LateResponse  = 0
}
Write-Step 'A) 20 fatura oluşturuluyor, kuyruk boşalana kadar bekleniyor'
$a = New-ServiceInvoices 20
$seconds = Wait-QueueDrained $a.From $a.To 120
Write-Host "  Kuyruk $seconds sn'de boşaldı."

$range = "invoice_number BETWEEN '$($a.From)' AND '$($a.To)'"
Write-DbHeader 'A) Success %100: fatura, outbox ve simülatör' "Fatura aralığı: $($a.From) .. $($a.To)"
Show-ServiceQuery "SELECT status, count(*) AS fatura, min(send_attempt_count) AS min_deneme, max(send_attempt_count) AS max_deneme FROM invoices WHERE $range GROUP BY 1;"
Show-ServiceQuery ("SELECT status, count(*) AS kayit, max(attempt_count) AS max_deneme, count(processed_at) AS processed_dolu, " +
    "count(locked_until) AS kilitli, count(last_error) AS hatali FROM erp_outbox WHERE $range GROUP BY 1;")
Show-ErpQuery "SELECT behavior, count(*) AS kayit, count(DISTINCT invoice_number) AS farkli_fatura FROM invoices WHERE $range GROUP BY 1;"

$outboxOk = [int]@(Get-ServiceRows ("SELECT count(*) FROM erp_outbox WHERE $range AND status = 'Tamamlandı' AND attempt_count = 1 " +
    "AND processed_at IS NOT NULL AND locked_until IS NULL AND locked_by IS NULL AND last_error IS NULL;"))[0]
$servicePairs = @(Get-ServiceRows "SELECT invoice_number || '=' || erp_reference FROM invoices WHERE $range AND status = 'Gönderildi' AND send_attempt_count = 1 ORDER BY 1;")
$erpPairs = @(Get-ErpRows "SELECT invoice_number || '=' || erp_reference FROM invoices WHERE $range ORDER BY 1;")
$same = @($servicePairs | Where-Object { $erpPairs -contains $_ }).Count
Write-Host ''
$ok = Write-DbVerdict ('20 fatura Gönderildi (1 deneme); 20 outbox Tamamlandı (1 deneme, processed_at dolu, kilit temiz); ' +
    'simülatörde 20 kayıt; 20 fatura no = erp_reference çifti iki tarafta aynı') `
    "$($servicePairs.Count) Gönderildi; $outboxOk outbox Tamamlandı; simülatörde $($erpPairs.Count) kayıt; $same çift aynı" `
    ($servicePairs.Count -eq 20 -and $outboxOk -eq 20 -and $erpPairs.Count -eq 20 -and $same -eq 20)
$allPassed = $allPassed -and $ok

# --- B) Aynı anda en fazla 10 -----------------------------------------------------------------------------------
Restart-Simulator @{
    Simulator__Rates__Success       = 0
    Simulator__Rates__Busy          = 0
    Simulator__Rates__ServerError   = 0
    Simulator__Rates__SaveThenError = 0
    Simulator__Rates__LateResponse  = 100
}
Write-Step 'B) 25 fatura oluşturuluyor; her gönderim 10 sn''de zaman aşımına düşecek'
$b = New-ServiceInvoices 25
$seconds = Wait-QueueDrained $b.From $b.To 180
Write-Host "  Kuyruk $seconds sn'de boşaldı (10'ar 10'ar gönderilirse ~30 sn)."

$range = "invoice_number BETWEEN '$($b.From)' AND '$($b.To)'"
Write-DbHeader 'B) Aynı anda kaç gönderim: simülatöre isteklerin geliş saatleri' "Fatura aralığı: $($b.From) .. $($b.To)"
Show-ErpQuery ("SELECT to_char(received_at, 'HH24:MI:SS') AS gelis_saniyesi, count(*) AS istek FROM invoices WHERE $range GROUP BY 1 ORDER BY 1;")
Show-ServiceQuery ("SELECT i.status AS fatura, o.status AS outbox, o.attempt_count AS deneme, left(o.last_error, 45) AS hata, count(*) " +
    "FROM invoices i JOIN erp_outbox o USING (invoice_number) WHERE i.$range GROUP BY 1, 2, 3, 4;")

# Her gönderim en az 10 sn sürer (zaman aşımı). Bir isteğin geldiği anda, ondan önceki 9,5 sn içinde gelmiş istekler
# hâlâ sürmektedir: bu sayı (isteğin kendisi dahil) o andaki eşzamanlı gönderim sayısıdır.
$inv = [Globalization.CultureInfo]::InvariantCulture
$arrivals = @(Get-ErpRows "SELECT extract(epoch FROM received_at) FROM invoices WHERE $range ORDER BY 1;" | ForEach-Object { [double]::Parse($_, $inv) })
$maxInFlight = 0
foreach ($t in $arrivals) {
    $n = @($arrivals | Where-Object { $_ -le $t -and $_ -gt $t - 9.5 }).Count
    if ($n -gt $maxInFlight) { $maxInFlight = $n }
}
$logMax = (@(Get-ServiceLog | Where-Object { $_ -match 'inFlight=(\d+)' } | ForEach-Object { [int]($_ -replace '^.*inFlight=(\d+).*$', '$1') }) |
    Measure-Object -Maximum).Maximum
$failed = [int]@(Get-ServiceRows ("SELECT count(*) FROM invoices i JOIN erp_outbox o USING (invoice_number) WHERE i.$range " +
    "AND i.status = 'Başarısız' AND o.status = 'Başarısız' AND o.attempt_count = 1 AND o.last_error LIKE '%zaman aşımı%';"))[0]
Write-Host ''
Write-Host '  (Bu adımda tek deneme olduğu için zaman aşımına düşen faturalar Başarısız; Adım 4''te tekrar denenecekler.)' -ForegroundColor DarkGray
$ok = Write-DbVerdict ('simülatöre 25 istek; aynı anda en fazla 10 gönderim (simülatör kayıt saatlerinden ve servis logundan); ' +
    '25 fatura ve outbox Başarısız, 1 deneme, hata zaman aşımı') `
    "$($arrivals.Count) istek; aynı anda en fazla $maxInFlight (servis logunda en fazla inFlight=$logMax); $failed Başarısız" `
    ($arrivals.Count -eq 25 -and $maxInFlight -eq 10 -and $logMax -le 10 -and $failed -eq 25)
$allPassed = $allPassed -and $ok

Restart-Simulator

Write-Result $allPassed 'worker kuyruğu boşaltıyor, sonucu fatura ve outbox''a birlikte yazıyor, aynı anda en fazla 10 gönderim yapıyor'
