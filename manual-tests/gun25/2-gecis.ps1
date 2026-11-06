# Kontrol listesi 3-6: yük altında kademeli geçiş, geri dönüş, yeniden geçiş, kuyruk doluyken v1'in kapatılması. Temiz veritabanı, simülatör
# varsayılan ayarlarıyla (hatalar ve haber sorunları açık), saniyede 50 fatura, her fatura farklı tutarda. Yük sürerken iptal de istenir.
# Sayım kuyruk boşaldıktan sonra son durumdan yapılır. Çıktı manual-tests\output\gun25\<-Etiket>.txt.
#   .\manual-tests\gun25\2-gecis.ps1
# İki kopyayla (yük ikisine dağıtılır, yüzde birine yazılıp ikisinden okunur): .\manual-tests\gun25\2-gecis.ps1 -IkiKopya -Etiket b-gecis-iki-kopya
param([string]$Etiket = 'b-gecis', [int]$Rate = 50, [int]$StepSeconds = 60, [switch]$IkiKopya)
. "$PSScriptRoot\_common.ps1"
Use-Gun10Volumes "gun25-gecis-$(Get-Date -Format 'MMddHHmm')"
[void](Use-BackupFolder 'yedek-diger')
# Yarıda kalmış bir koşunun k6'sı sürüyorsa bu koşunun yüküne karışır.
docker ps -q --filter 'label=com.docker.compose.service=k6' | ForEach-Object { docker rm -f $_ | Out-Null }
New-Report $Etiket
Write-Title "ERP sürüm geçişi: saniyede $Rate fatura, adım başına $StepSeconds sn"
Start-Stack
if ($IkiKopya) {
    Push-Location $RepoRoot; docker compose --profile iki-kopya up -d --build invoice-service-2 2>&1 | Out-Null; Pop-Location
    $secondUrl = 'http://127.0.0.1:5091'
    for ($i = 0; $i -lt 60; $i++) { try { if ((Invoke-WebRequest "$secondUrl/health" -UseBasicParsing).StatusCode -eq 200) { break } } catch { Start-Sleep -Seconds 2 } }
}
Restart-Simulator
$runId = "GUN25-$(Get-Date -Format 'yyyyMMddTHHmmss')"
Write-Line "Koşu: $(Get-Date -Format 'yyyy-MM-dd HH:mm'), RUN_ID $runId"

$script:Token = $null; $script:TokenAt = [datetime]::MinValue
function Get-OperatorToken {
    if (((Get-Date) - $script:TokenAt).TotalMinutes -gt 4) { $script:Token = Get-UserToken 'operator'; $script:TokenAt = Get-Date }
    $script:Token
}
function Get-Numbers([string]$Sql) { @((Invoke-InvoiceSql $Sql) -split "`r?`n" | Where-Object { $_ -match '^FTR-' }) }
function Get-ErpNumbers([string]$Sql) { @((Get-SqlScalar $Sql) -split "`r?`n" | Where-Object { $_ -match '^FTR-' }) }
function Get-Count([string]$Sql) { [int](Invoke-InvoiceSql $Sql) }
function In-ListOf($Numbers) { (@($Numbers) | ForEach-Object { "'$_'" }) -join ',' }
$noCancel = "NOT EXISTS (SELECT 1 FROM erp_outbox c WHERE c.invoice_number = i.invoice_number AND c.kind = 'İptal')"
$requested = [Collections.Generic.List[string]]::new()
function Request-Cancels($Numbers) {
    $ok = 0
    foreach ($number in @($Numbers)) {
        $r = Send-Api POST "/api/v1/invoices/$number/cancel" (Get-OperatorToken)
        if ($r.Status -eq 202) { $requested.Add($number); $ok++ }
    }
    $ok
}
# Adım boyunca her 5 sn'de kuyruktaki ve ERP'ye ulaşmış faturalardan iptal istenir.
function Wait-StepWithCancels([int]$Seconds) {
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        [void](Request-Cancels (Get-Numbers "SELECT i.invoice_number FROM invoices i WHERE i.customer_code = '$runId' AND i.status = 'Bekliyor' AND i.send_attempt_count = 0 AND $noCancel ORDER BY i.invoice_number DESC LIMIT 5"))
        [void](Request-Cancels (Get-Numbers "SELECT i.invoice_number FROM invoices i WHERE i.customer_code = '$runId' AND i.status IN ('Gönderildi', 'İşleme Alındı', 'Onaylandı') AND $noCancel ORDER BY random() LIMIT 5"))
        Start-Sleep -Seconds 5
    }
}
$phases = [Collections.Generic.List[object]]::new()
function Start-Phase([string]$Name, [int]$Percent) {
    if ($Percent -ge 0) {
        Set-V2Percent $Percent
        if ($IkiKopya) {
            $seen = Invoke-RestMethod "$secondUrl/api/v1/erp-version" -Headers @{ Authorization = "Bearer $(Get-OperatorToken)" }
            Check ($seen.v2Percent -eq $Percent) "Birinci kopyaya yazılan $Percent, ikinci kopyadan okunan $($seen.v2Percent)"
        }
    }
    $at = Get-SqlScalar "SELECT now()"
    $phases.Add([pscustomobject]@{ Name = $Name; From = $at })
    Write-Line "  $(Get-Date -Format 'HH:mm:ss') $Name"
}
function Get-EarlyCancels { @(Get-SimulatorLog | Where-Object { "$_" -match 'ERP cancel invoice=\S+ status=404 reason=notRecorded' }).Count }

Write-Line ''
Write-Line '1) k6 başlıyor; adımlar yük altında'
$total = 7 * $StepSeconds
$k6Job = Start-Job -ScriptBlock { param($root, $composeFile, $vol, $rate, $duration, $run, $bases)
    Set-Location $root; $env:COMPOSE_FILE = $composeFile; $env:GUN10_VOL = $vol; $env:RATE = $rate; $env:DURATION = $duration; $env:RUN_ID = $run; $env:VARY_AMOUNTS = 'true'; if ($bases) { $env:BASE_URLS = $bases }
    docker compose --profile yuk-testi run --rm k6 2>&1 } -ArgumentList $RepoRoot, $env:COMPOSE_FILE, $env:GUN10_VOL, "$Rate", "${total}s", $runId, $(if ($IkiKopya) { 'http://invoice-service:8080,http://invoice-service-2:8080' } else { '' })

Start-Phase 'yüzde 0 (yalnız v1)' 0
Wait-StepWithCancels $StepSeconds
# Geçişten önce v1 ile ERP'ye ulaşmış faturalar: iptalleri geçişten sonra istenecek.
$beforeMove = Get-ErpNumbers "SELECT invoice_number FROM invoices WHERE customer_code = '$runId' AND api_version = 1 ORDER BY random() LIMIT 300"
$beforeMove = @($beforeMove | Where-Object { -not $requested.Contains($_) })
if ($beforeMove.Count -lt 30) { throw "Geçişten önce v1 ile gönderilmiş yeterli fatura yok: $($beforeMove.Count)" }
Start-Phase 'yüzde 10' 10
Wait-StepWithCancels $StepSeconds
Start-Phase 'yüzde 50' 50
Wait-StepWithCancels $StepSeconds
Start-Phase 'yüzde 100' 100
$third = [int][math]::Floor($beforeMove.Count / 3)
$cancelAfterMove = @($beforeMove | Select-Object -First $third)
$okAfterMove = Request-Cancels $cancelAfterMove
Write-Line "    Geçişten önce v1 ile gönderilmiş $($cancelAfterMove.Count) faturadan $okAfterMove tanesinin iptali yüzde 100'de istendi"
Wait-StepWithCancels $StepSeconds
Start-Phase 'geri dönüş: yüzde 0' 0
$rollbackAt = $phases[$phases.Count - 1].From
Wait-StepWithCancels $StepSeconds
Start-Phase 'yeniden yüzde 100' 100
Wait-StepWithCancels $StepSeconds

$earlyBeforeClose = Get-EarlyCancels
$pendingAtClose = Get-Count "SELECT count(*) FROM erp_outbox WHERE status = 'Bekliyor'"
Start-Phase 'v1 kapatıldı (kuyruk dolu)' -1
Write-Line "    Kapatma anında kuyrukta $pendingAtClose satır"
Restart-Simulator @{ Simulator__V1Enabled = 'false' }
$closedAt = Get-SqlScalar "SELECT now()"
$cancelClosed = @($beforeMove | Select-Object -Skip $third -First $third)
$okClosed = Request-Cancels $cancelClosed
Write-Line "    v1 kapalıyken, v1 ile gönderilmiş $($cancelClosed.Count) faturadan $okClosed tanesinin iptali istendi"
# Yanlışlıkla geri çekilse de kuyruktaki işler 410 ile v2'ye gider.
Start-Phase 'v1 kapalıyken yüzde 0 (30 sn, yanlış ayar)' 0
Wait-StepWithCancels 30
Start-Phase 'v1 kapalı, yüzde 100' 100
$k6Out = Receive-Job $k6Job -Wait -AutoRemoveJob
$k6 = Get-Content (Join-Path $RepoRoot "load-test\results\$runId.json") -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Line "  k6: $($k6.requests) istek, $($k6.accepted) kabul (202), p95 $([Math]::Round($k6.durationMs.p95, 1)) ms"

Write-Line ''
Write-Line '2) Kuyruğun boşalması'
$deadline = (Get-Date).AddMinutes(90)
do {
    $pending = Get-Count "SELECT count(*) FROM erp_outbox WHERE status = 'Bekliyor'"
    if ($pending -gt 0) { Start-Sleep -Seconds 15 }
} while ($pending -gt 0 -and (Get-Date) -lt $deadline)
Check ($pending -eq 0) "Kuyrukta bekleyen fatura ya da iptal: $pending ($(Get-Date -Format 'HH:mm:ss'))"
Start-Sleep -Seconds 120
$state = Invoke-ReconciliationRetry
Check ($state.status -eq 'Tamamlandı') "Mutabakat $($state.id): $($state.status), kontrol $($state.checkedCount), düzeltilen $($state.fixedCount), raporlanan $($state.reportedCount)"
Show-Rows 'Bulgular:' "SELECT finding_type, action, count(*) FROM reconciliation_findings WHERE run_id = $($state.id) GROUP BY 1, 2 ORDER BY 1, 2"

Write-Line ''
Write-Line '3) Kademe (kontrol 3): adımlarda ERP''ye giren kayıtlar, sürüme göre'
for ($i = 0; $i -lt $phases.Count; $i++) {
    $from = $phases[$i].From
    $until = if ($i + 1 -lt $phases.Count) { "AND received_at < '$($phases[$i + 1].From)'" } else { '' }
    $row = Get-SqlScalar "SELECT coalesce(sum((api_version = 1)::int), 0) || '|' || coalesce(sum((api_version = 2)::int), 0) FROM invoices WHERE customer_code = '$runId' AND received_at >= '$from' $until"
    $parts = $row -split '\|'; $sum = [int]$parts[0] + [int]$parts[1]
    $share = if ($sum) { [Math]::Round(100 * [int]$parts[1] / $sum, 1) } else { 0 }
    Write-Line "  $($phases[$i].Name): v1 $($parts[0]), v2 $($parts[1]) (v2 yüzde $share)"
}

Write-Line ''
Write-Line '4) ERP ile karşılaştırma (kontrol 3, 5)'
$service = @{}
foreach ($line in ((Invoke-InvoiceSql "SELECT invoice_number || '|' || amount || '|' || status FROM invoices WHERE customer_code = '$runId'") -split "`r?`n")) { if ($line) { $p = $line -split '\|'; $service[$p[0]] = $p } }
$erp = @{}
foreach ($line in ((Get-SqlScalar "SELECT invoice_number || '|' || amount FROM invoices WHERE customer_code = '$runId'") -split "`r?`n")) { if ($line) { $p = $line -split '\|'; if ($erp.ContainsKey($p[0])) { $erp[$p[0]] += ,$p[1] } else { $erp[$p[0]] = @($p[1]) } } }
$acceptedMissing = [int]$k6.accepted - $service.Count
Check ($acceptedMissing -eq 0) "k6'nın 202 aldığı ama serviste olmayan: $acceptedMissing (serviste $($service.Count))"
$sentStates = 'Gönderildi', 'İşleme Alındı', 'Onaylandı', 'Reddedildi'
$lost = @($service.Values | Where-Object { $_[2] -in $sentStates -and -not $erp.ContainsKey($_[0]) }).Count
Check ($lost -eq 0) "ERP'ye ulaşmış görünüp ERP'de olmayan (kaybolan): $lost"
$double = @($erp.Keys | Where-Object { $erp[$_].Count -gt 1 })
Check ($double.Count -eq 0) "ERP'de birden fazla kaydı olan fatura numarası (çift): $($double.Count)"
$rollbackDouble = Get-SqlScalar "SELECT count(*) FROM (SELECT invoice_number FROM invoices WHERE customer_code = '$runId' AND received_at >= '$rollbackAt' GROUP BY 1 HAVING count(*) > 1) t"
Write-Line "  Geri dönüşten sonra oluşan çift: $rollbackDouble"
$amountDiff = 0
foreach ($number in $erp.Keys) {
    if (-not $service.ContainsKey($number)) { continue }
    $s = [decimal]::Parse($service[$number][1], [Globalization.CultureInfo]::InvariantCulture)
    foreach ($a in $erp[$number]) { if ([decimal]::Parse($a, [Globalization.CultureInfo]::InvariantCulture) -ne $s) { $amountDiff++ } }
}
Check ($amountDiff -eq 0) "Tutarı farklı kayıt: $amountDiff (karşılaştırılan $($erp.Count) fatura)"
$extra = @($erp.Keys | Where-Object { -not $service.ContainsKey($_) }).Count
Check ($extra -eq 0) "ERP'de olup serviste olmayan: $extra"
Show-Rows 'ERP''deki kayıtlar, sürüme göre:' "SELECT api_version, count(*), count(DISTINCT invoice_number) FROM invoices WHERE customer_code = '$runId' GROUP BY 1 ORDER BY 1" -Erp
$failedInvoices = Get-Count "SELECT count(*) FROM invoices WHERE customer_code = '$runId' AND status = 'Başarısız'"
Check ($failedInvoices -eq 0) "Başarısız kalan fatura: $failedInvoices"

Write-Line ''
Write-Line '5) Faturasından önce ulaşan iptal (kontrol 5)'
$earlyAfterClose = Get-EarlyCancels
$early = $earlyBeforeClose + $earlyAfterClose
Check ($early -eq 0) "Simülatör logunda status=404 reason=notRecorded: v1 kapatılmadan önce $earlyBeforeClose, sonra $earlyAfterClose"
$earlyRows = Get-SqlScalar ("SELECT count(*) FROM cancellations c WHERE NOT EXISTS (SELECT 1 FROM invoices i WHERE i.invoice_number = c.invoice_number AND i.received_at < c.cancelled_at)")
Check ($earlyRows -eq '0') "Faturasının kaydından önce oluşan iptal kaydı: $earlyRows"

Write-Line ''
Write-Line '6) Geçişten önce v1 ile gönderilen faturaların iptali ve haberleri (kontrol 4)'
foreach ($set in @(@('yüzde 100''de istenen', $cancelAfterMove), @('v1 kapalıyken istenen', $cancelClosed))) {
    $list = In-ListOf $set[1]
    $rows = (Invoke-InvoiceSql "SELECT status || ': ' || count(*) FROM invoices WHERE invoice_number IN ($list) GROUP BY status ORDER BY 1") -replace "`r?`n", ', '
    Write-Line "  $($set[0]), son durum: $rows"
    $bad = Get-Count "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status NOT IN ('İptal Edildi', 'Reddedildi')"
    Check ($bad -eq 0) "$($set[0]): İptal Edildi ya da Reddedildi dışında kalan: $bad"
    $inErp = Get-SqlScalar "SELECT count(*) FROM cancellations WHERE invoice_number IN ($list)"
    Write-Line "    ERP'de iptal kaydı: $inErp"
}
$v1Numbers = Get-ErpNumbers "SELECT invoice_number FROM invoices WHERE customer_code = '$runId' AND api_version = 1"
$v1Set = [Collections.Generic.HashSet[string]]::new([string[]]$v1Numbers)
$formats = (Invoke-InvoiceSql "SELECT invoice_number || '|' || event_type || '|' || (payload::jsonb ? 'schema')::text FROM erp_webhook_events WHERE invoice_number LIKE 'FTR-%'") -split "`r?`n"
$wrong = 0; $counts = @{}
foreach ($line in $formats) {
    if (-not $line) { continue }
    $p = $line -split '\|'
    if (-not $erp.ContainsKey($p[0])) { continue }
    $isV2Format = $p[2] -eq 'true'; $isV1Invoice = $v1Set.Contains($p[0])
    $key = "$(if ($isV1Invoice) { 'v1' } else { 'v2' }) faturası, $(if ($isV2Format) { 'yeni' } else { 'eski' }) biçim, $($p[1])"
    $counts[$key] = 1 + [int]$counts[$key]
    if ($isV2Format -eq $isV1Invoice) { $wrong++ }
}
$counts.Keys | Sort-Object | ForEach-Object { Write-Line "    $_ : $($counts[$_])" }
Check ($wrong -eq 0) "Faturanın alındığı sürümle biçimi uymayan haber: $wrong"
$v2Rejected = Get-Count "SELECT count(*) FROM invoices WHERE customer_code = '$runId' AND status = 'Reddedildi' AND coalesce(reject_reason, '') = ''"
Check ($v2Rejected -eq 0) "Nedeni boş Reddedildi fatura: $v2Rejected"

Write-Line ''
Write-Line '7) v1 kapatıldıktan sonra (kontrol 6)'
$v1After = Get-SqlScalar "SELECT count(*) FROM invoices WHERE customer_code = '$runId' AND api_version = 1 AND received_at >= '$closedAt'"
Check ($v1After -eq '0') "v1 kapandıktan sonra v1 ile alınan kayıt: $v1After"
$gone = @(Get-SimulatorLog | Where-Object { "$_" -match 'status=410 reason=v1Closed' }).Count
Write-Line "  v1'in 410 ile reddettiği istek: $gone (yanlış ayar sırasında beklenir)"
Show-Rows 'Satırlar, son durum:' "SELECT kind, status, count(*) FROM erp_outbox GROUP BY 1, 2 ORDER BY 1, 2"
$stuck = Get-Count "SELECT count(*) FROM erp_outbox WHERE status = 'Bekliyor'"
Check ($stuck -eq 0) "Takılı fatura ya da iptal: $stuck"
$cancelFailed = Get-Count "SELECT count(*) FROM erp_outbox o WHERE o.kind = 'İptal' AND o.status = 'Başarısız'"
Show-Rows 'Başarısız iptallerin faturası:' "SELECT i.status, left(o.last_error, 70), count(*) FROM erp_outbox o JOIN invoices i USING (invoice_number) WHERE o.kind = 'İptal' AND o.status = 'Başarısız' GROUP BY 1, 2 ORDER BY 3 DESC"
$closedErrors = Get-Count "SELECT count(*) FROM erp_outbox WHERE last_error LIKE '%410%' AND status = 'Başarısız'"
Check ($closedErrors -eq 0) "410 yüzünden Başarısız olan satır: $closedErrors"
$final = Invoke-ReconciliationRetry
Check ($final.status -eq 'Tamamlandı') "v1 kapalıyken son mutabakat $($final.id): $($final.status), kontrol $($final.checkedCount), düzeltilen $($final.fixedCount), raporlanan $($final.reportedCount)"
Show-Rows 'Son mutabakatın bulguları:' "SELECT finding_type, action, count(*) FROM reconciliation_findings WHERE run_id = $($final.id) GROUP BY 1, 2 ORDER BY 1, 2"
foreach ($type in 'Serviste Yok', 'ERP Kaydı Yok', 'ERP Çift Kayıt', 'Alan Farkı', 'Cevap Alınamadı') {
    $n = Get-Count "SELECT count(*) FROM reconciliation_findings WHERE run_id = $($final.id) AND finding_type = '$type'"
    Check ($n -eq 0) "${type}: $n"
}
Write-Line ''
Write-Line '8) Yetki ve kopyalar'
Push-Location $RepoRoot
$services = if ($IkiKopya) { 'invoice-service', 'invoice-service-2', 'erp-simulator' } else { 'invoice-service', 'erp-simulator' }
$permissionErrors = @($services | ForEach-Object { docker compose logs --no-color $_ 2>&1 } | ForEach-Object { "$_" } | Where-Object { $_ -match 'permission denied|42501:' }).Count
Check ($permissionErrors -eq 0) "Servis ve simülatör loglarında yetki hatası: $permissionErrors"
if ($IkiKopya) {
    foreach ($copy in 'invoice-service', 'invoice-service-2') {
        $sends = @(docker compose logs --no-color $copy 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'check=' }).Count
        Check ($sends -gt 0) "${copy}: ERP deneme logu $sends"
    }
    docker compose --profile iki-kopya stop invoice-service-2 2>&1 | Out-Null
}
Pop-Location
Set-V2Percent 100
Restart-Simulator
Save-Report
