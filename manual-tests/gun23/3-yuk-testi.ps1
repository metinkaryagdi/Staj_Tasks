# Kontrol listesi 7: saniyede 50 fatura, 2 dakika, faturaların yaklaşık onda biri iptal ediliyor. k6 yalnız fatura oluşturur; bu script
# yük sürerken iptal ister: bir kısmı hâlâ kuyruktaki, bir kısmı ERP'ye ulaşmış faturalar. Simülatör varsayılan ayarlarıyla çalışır
# (yanlış imza, tekrar, sıra karışması, kayıp haber açık). Kuyruk boşalınca mutabakat başlatılır; sayım son durumdan yapılır.
# Çıktı manual-tests\output\gun23\<-Etiket>.txt. ~25 dk.
#   .\manual-tests\gun23\3-yuk-testi.ps1
param([string]$Etiket = 'c-yuk-testi', [int]$Rate = 50, [string]$Duration = '2m', [int]$PerArm = 300)
. "$PSScriptRoot\_common.ps1"

New-Report $Etiket
Write-Title "Yük testi: saniyede $Rate fatura, $Duration, faturaların yaklaşık onda biri iptal"
Start-Stack
Restart-Simulator
$runId = "GUN23-YUK-$(Get-Date -Format 'yyyyMMddTHHmmss')"
Write-Line "Koşu: $(Get-Date -Format 'yyyy-MM-dd HH:mm'), RUN_ID $runId"

$script:Token = $null; $script:TokenAt = [datetime]::MinValue
function Get-OperatorToken {
    if (((Get-Date) - $script:TokenAt).TotalMinutes -gt 4) { $script:Token = Get-UserToken 'operator'; $script:TokenAt = Get-Date }
    $script:Token
}
function Get-Numbers([string]$Sql) { @((Invoke-InvoiceSql $Sql) -split "`r?`n" | Where-Object { $_ -match '^FTR-' }) }
function Get-Count([string]$Sql) { [int](Invoke-InvoiceSql $Sql) }
function In-ListOf($Numbers) { (@($Numbers) | ForEach-Object { "'$_'" }) -join ',' }

Write-Line ''
Write-Line '1) k6 fatura oluşturuyor, yük sürerken iptal isteniyor'
$env:RATE = "$Rate"; $env:DURATION = $Duration; $env:RUN_ID = $runId
$k6Job = Start-Job -ScriptBlock { param($root, $composeFile, $vol, $rate, $duration, $run)
    Set-Location $root; $env:COMPOSE_FILE = $composeFile; $env:GUN10_VOL = $vol; $env:RATE = $rate; $env:DURATION = $duration; $env:RUN_ID = $run
    docker compose --profile yuk-testi run --rm k6 2>&1 } -ArgumentList $RepoRoot, $env:COMPOSE_FILE, $env:GUN10_VOL, "$Rate", $Duration, $runId

$noCancel = "NOT EXISTS (SELECT 1 FROM erp_outbox c WHERE c.invoice_number = i.invoice_number AND c.kind = 'İptal')"
$requested = [Collections.Generic.List[string]]::new()
$queueArm = 0; $erpArm = 0; $codes = @{}
function Request-Many([string[]]$Numbers) {
    foreach ($number in $Numbers) {
        $r = Send-Api POST "/api/v1/invoices/$number/cancel" (Get-OperatorToken)
        $codes["$($r.Status)"] = 1 + [int]$codes["$($r.Status)"]
        if ($r.Status -eq 202) { $requested.Add($number) }
    }
}
do {
    Start-Sleep -Seconds 3
    if ($queueArm -lt $PerArm) {
        $queued = Get-Numbers "SELECT i.invoice_number FROM invoices i WHERE i.customer_code = '$runId' AND i.status = 'Bekliyor' AND i.send_attempt_count = 0 AND $noCancel ORDER BY i.invoice_number DESC LIMIT 15"
        Request-Many $queued
        $queueArm += $queued.Count
    }
    if ($erpArm -lt $PerArm) {
        $atErp = Get-Numbers "SELECT i.invoice_number FROM invoices i WHERE i.customer_code = '$runId' AND i.status IN ('Gönderildi', 'İşleme Alındı', 'Onaylandı') AND $noCancel ORDER BY random() LIMIT 15"
        Request-Many $atErp
        $erpArm += $atErp.Count
    }
} while ($queueArm -lt $PerArm -or $erpArm -lt $PerArm)
Write-Line "  İptal isteği: kuyruktaki faturaya $queueArm, ERP'ye ulaşmış faturaya $erpArm; cevaplar: $(($codes.Keys | ForEach-Object { "HTTP $_ x $($codes[$_])" }) -join ', ')"

$k6Out = Receive-Job $k6Job -Wait -AutoRemoveJob
$k6 = Get-Content (Join-Path $RepoRoot "load-test\results\$runId.json") -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Line "  k6: $($k6.requests) istek, $($k6.accepted) kabul (202); 401 alan istek $($k6.unauthorized401), p95 $([Math]::Round($k6.durationMs.p95, 1)) ms"

Write-Line ''
Write-Line '2) Kuyruğun boşalması'
$deadline = (Get-Date).AddMinutes(40)
do {
    $pending = Get-Count "SELECT count(*) FROM erp_outbox o JOIN invoices i ON i.invoice_number = o.invoice_number WHERE i.customer_code = '$runId' AND o.status = 'Bekliyor'"
    if ($pending -gt 0) { Start-Sleep -Seconds 15 }
} while ($pending -gt 0 -and (Get-Date) -lt $deadline)
Check ($pending -eq 0) "Kuyrukta bekleyen: $pending ($(Get-Date -Format 'HH:mm:ss'))"
Write-Line '  Haberlerin gelmesi için 60 sn bekleniyor, sonra mutabakat başlatılıyor'
Start-Sleep -Seconds 60
$cancelledBefore = Get-Count "SELECT count(*) FROM invoices WHERE customer_code = '$runId' AND status = 'İptal Edildi'"
$state = Invoke-Reconciliation
Check ($state.status -eq 'Tamamlandı') "Mutabakat $($state.id): $($state.status), kontrol edilen $($state.checkedCount), düzeltilen $($state.fixedCount), raporlanan $($state.reportedCount)"
Write-Line "  Mutabakattan önce İptal Edildi: $cancelledBefore"
Show-Rows 'Bu mutabakatın bulguları:' "SELECT finding_type, action, count(*) FROM reconciliation_findings WHERE run_id = $($state.id) GROUP BY 1, 2 ORDER BY 1, 2"

Write-Line ''
Write-Line '3) Kayıp ve çift kayıt'
$created = Get-Count "SELECT count(*) FROM invoices WHERE customer_code = '$runId'"
Check (($k6.accepted - $created) -eq 0) "k6'nın 202 aldığı ama serviste olmayan: $($k6.accepted - $created)"
$erpRow = (Get-SqlScalar "SELECT count(DISTINCT invoice_number) || '|' || count(*) FROM invoices WHERE customer_code = '$runId'") -split '\|'
Write-Line "  Serviste $created fatura; ERP'de $($erpRow[0]) farklı fatura numarası, $($erpRow[1]) kayıt"
Check ($erpRow[0] -eq $erpRow[1]) "ERP'de birden fazla kaydı olan fatura numarası: $([int]$erpRow[1] - [int]$erpRow[0])"
$erpNumbers = [Collections.Generic.HashSet[string]]::new([string[]]@((Get-SqlScalar "SELECT DISTINCT invoice_number FROM invoices WHERE customer_code = '$runId'") -split "`r?`n"))
$completed = Get-Numbers "SELECT o.invoice_number FROM erp_outbox o JOIN invoices i ON i.invoice_number = o.invoice_number WHERE i.customer_code = '$runId' AND o.kind = 'Gönderim' AND o.status = 'Tamamlandı'"
$missing = @($completed | Where-Object { -not $erpNumbers.Contains($_) }).Count
Check ($missing -eq 0) "Serviste gönderimi tamamlanmış ama ERP'de kaydı olmayan: $missing (tamamlanan $($completed.Count))"
$failedSends = Get-Count "SELECT count(*) FROM invoices WHERE customer_code = '$runId' AND status = 'Başarısız'"
Check ($failedSends -eq 0) "Başarısız kalan fatura: $failedSends"

Write-Line ''
Write-Line '4) Faturasından önce ERP''ye ulaşan iptal'
$early = Get-SqlScalar ("SELECT count(*) FROM cancellations c WHERE c.invoice_number IN (SELECT invoice_number FROM invoices WHERE customer_code = '$runId') " +
    "AND NOT EXISTS (SELECT 1 FROM invoices i WHERE i.invoice_number = c.invoice_number AND i.received_at < c.cancelled_at)")
Check ($early -eq '0') "Faturasının kaydından önce oluşan ya da faturası olmayan iptal kaydı: $early"
$orphans = [int](Get-SqlScalar "SELECT count(*) FROM cancellations c WHERE NOT EXISTS (SELECT 1 FROM invoices i WHERE i.invoice_number = c.invoice_number)")
Check ($orphans -eq 0) "ERP'de faturası olmayan iptal kaydı: $orphans"
# ERP, kaydı olmayan faturanın iptaline 404 döner ve satır yazmaz: erken gelen iptal yukarıdaki sorgularda görünmez, logda görünür.
$earlyRequests = @(Get-SimulatorLog | Where-Object { "$_" -match 'ERP cancel invoice=\S+ status=404 reason=notRecorded' }).Count
Check ($earlyRequests -eq 0) "ERP'ye faturasından önce gelen iptal isteği (simülatör logunda status=404 reason=notRecorded): $earlyRequests"

Write-Line ''
Write-Line '5) İptal edilen her fatura sonunda İptal Edildi (sayım son durumdan)'
$list = In-ListOf $requested
Show-Rows 'İptali kabul edilen faturaların son durumu:' "SELECT status, count(*) FROM invoices WHERE invoice_number IN ($list) GROUP BY 1 ORDER BY 1"
$cancelled = Get-Numbers "SELECT invoice_number FROM invoices WHERE invoice_number IN ($list) AND status = 'İptal Edildi'"
$rejected = Get-Count "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status = 'Reddedildi'"
$others = $requested.Count - $cancelled.Count - $rejected
Write-Line "  İptali kabul edilen $($requested.Count): İptal Edildi $($cancelled.Count), isteği alınıp Reddedildi biten $rejected, başka durumda $others"
Check ($others -eq 0) "Reddedilmemiş olup İptal Edildi olmayan: $others"
$cancelledAtErp = @((Get-SqlScalar "SELECT invoice_number FROM cancellations WHERE invoice_number IN ($(In-ListOf $cancelled))") -split "`r?`n" | Where-Object { $_ -match '^FTR-' }).Count
$nothingSent = @($cancelled | Where-Object { -not $erpNumbers.Contains($_) }).Count
Write-Line "  İptal Edildi olanlardan ERP'ye iptal giden $cancelledAtErp, ERP'ye hiçbir şey gitmeyen $nothingSent"
Check (($cancelledAtErp + $nothingSent) -eq $cancelled.Count) "ERP'de faturası olup iptali olmayan İptal Edildi: $($cancelled.Count - $cancelledAtErp - $nothingSent)"

Write-Line ''
Write-Line '6) Veritabanı yetkileri (uygulamalar invoice_app / erp_app ile)'
Push-Location $RepoRoot
$permissionErrors = @(docker compose logs --since 60m invoice-service erp-simulator 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'permission denied|42501:' })
Pop-Location
Check ($permissionErrors.Count -eq 0) "Son 60 dk'da invoice-service ve erp-simulator loglarında yetki hatası: $($permissionErrors.Count)"

Save-Report
