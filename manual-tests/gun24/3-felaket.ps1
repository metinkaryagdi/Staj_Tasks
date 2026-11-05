# Kontrol listesi 3-6: saniyede 50 fatura yükü altında veritabanı silinir, son yedekten geri dönülür. Yedek gerçek düzeninde (5 dk) alınır;
# yük bir sonraki yedekten 30 sn önce başlar: yedekte kuyruk olur ve bu kuyruk silmeden önce erir. Silme, yedekten sonra alınıp ERP'ye ulaşan
# sonraki yedekten hemen önce, sabit anda yapılır (-DeleteAfterSeconds); bu an aşağıda yazılır. Simülatör varsayılan ayarlarıyla çalışır.
# Sayımın kaynakları: silmeden sonra kaydedilen servis logu, geri yüklenen veritabanı, ERP veritabanı. Çıktı
# manual-tests\output\gun24\<-Etiket>.txt. ~1 saat 45 dk (iki yedek turu, yük, kuyruk, son haberden 65 dk sonra mutabakat).
#   .\manual-tests\gun24\3-felaket.ps1 -Etiket c-felaket-5dk -Name felaket-5dk
# 15 dakikalık sıklıkla karşılaştırma koşusu; silme, yedekten sonra alınıp ERP'ye ulaşan yeterli fatura ve iptal görülünce (~2,5 saat):
#   .\manual-tests\gun24\3-felaket.ps1 -IntervalSeconds 900 -DeleteAfterSeconds 0
param([string]$Etiket = 'c-felaket', [int]$Rate = 50, [string]$Duration = '8m', [int]$LeadSeconds = 30,
      [int]$EnoughAtErp = 200, [int]$EnoughCancelled = 20, [int]$MaxMinutesAfterBackup = 12, [int]$WaitForUnknownMinutes = 65,
      [string]$Name = 'felaket', [int]$IntervalSeconds = 300, [int]$DeleteAfterSeconds = 280)
. "$PSScriptRoot\_common.ps1"
Use-Gun10Volumes "gun24-$Name"
$backupDir = Use-BackupFolder "$Name-yedek"
$env:BACKUP_INTERVAL_SECONDS = "$IntervalSeconds"
$Bash = 'C:\Program Files\Git\bin\bash.exe'
$Volume = "staj-tasks_invoice-db-data-gun24-$Name"

New-Report $Etiket
Write-Title 'Felaket: yük altında veritabanı silinip son yedekten dönülüyor'
Write-Line "Koşu: $(Get-Date -Format 'yyyy-MM-dd HH:mm'), yedek aralığı $IntervalSeconds sn"
$runId = "GUN24-FELAKET-$(Get-Date -Format 'yyyyMMddTHHmmss')"

Push-Location $RepoRoot
try { docker compose down -v --remove-orphans 2>&1 | Out-Null } finally { Pop-Location }
Get-ChildItem $backupDir -Force | Remove-Item -Force
Start-Stack
Restart-Simulator
$clockDiff = ((Get-Date).ToUniversalTime() - ([DateTimeOffset](Invoke-InvoiceSql "SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.MS') || '+00:00'")).UtcDateTime).TotalSeconds
Write-Line ("Bilgisayar ile veritabanı saati farkı: {0:0.0} sn" -f $clockDiff)

function Get-BackupFiles { @(Get-ChildItem $backupDir -Filter 'invoice_*.dump' | Sort-Object Name) }
function Get-BackupTime($File) {
    [DateTimeOffset]::ParseExact(($File.Name -replace '^invoice_|\.dump$', ''), "yyyyMMdd'T'HHmmss'Z'", [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal)
}
function Get-Iso([DateTimeOffset]$At) { $At.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'") }
function Show-BackupLog {
    Push-Location $RepoRoot
    try { docker compose logs --no-color --no-log-prefix invoice-db-backup 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'yedek' } | ForEach-Object { Write-Line "    $_" } }
    finally { Pop-Location }
}

Write-Line ''
Write-Line '1) Yedekler düzenli alınıyor: birkaç fatura, sonra iki yedek turu'
1..3 | ForEach-Object { [void](New-Invoice) }
Push-Location $RepoRoot
try { docker compose restart invoice-db-backup 2>&1 | Out-Null } finally { Pop-Location }
$deadline = (Get-Date).AddSeconds($IntervalSeconds * 3 + 300)
while ((Get-BackupFiles).Count -lt 3 -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 15 }
Show-BackupLog
Check ((Get-BackupFiles).Count -ge 3) "Yedek dosyası: $((Get-BackupFiles).Count)"
Save-Report

Write-Line ''
Write-Line "2) Yük, bir sonraki yedekten $LeadSeconds sn önce başlıyor"
$lastBackup = Get-BackupFiles | Select-Object -Last 1
$nextBackup = (Get-BackupTime $lastBackup).AddSeconds($IntervalSeconds)
$startAt = $nextBackup.AddSeconds(-$LeadSeconds)
Write-Line "  Son yedek $($lastBackup.Name), beklenen sonraki $(Get-Iso $nextBackup), yük $(Get-Iso $startAt)"
while ([DateTimeOffset]::UtcNow -lt $startAt) { Start-Sleep -Milliseconds 500 }

$env:RATE = "$Rate"; $env:DURATION = $Duration; $env:RUN_ID = $runId
$k6Job = Start-Job -ScriptBlock { param($root, $composeFile, $vol, $rate, $duration, $run, $dir, $interval)
    Set-Location $root; $env:COMPOSE_FILE = $composeFile; $env:GUN10_VOL = $vol; $env:RATE = $rate; $env:DURATION = $duration; $env:RUN_ID = $run; $env:INVOICE_BACKUP_DIR = $dir; $env:BACKUP_INTERVAL_SECONDS = $interval
    docker compose --profile yuk-testi run --rm k6 2>&1 } -ArgumentList $RepoRoot, $env:COMPOSE_FILE, $env:GUN10_VOL, "$Rate", $Duration, $runId, $env:INVOICE_BACKUP_DIR, "$IntervalSeconds"
$loadStarted = [DateTimeOffset]::UtcNow

$script:Token = $null; $script:TokenAt = [datetime]::MinValue
function Get-OperatorToken {
    if (((Get-Date) - $script:TokenAt).TotalMinutes -gt 4) { $script:Token = Get-UserToken 'operator'; $script:TokenAt = Get-Date }
    $script:Token
}
$noCancel = "NOT EXISTS (SELECT 1 FROM erp_outbox c WHERE c.invoice_number = i.invoice_number AND c.kind = 'İptal')"
$atErpStates = "('Gönderildi', 'İşleme Alındı', 'Onaylandı')"
$codes = @{}
$newRequested = [Collections.Generic.List[string]]::new()
function Get-Numbers([string]$Sql) { @((Invoke-InvoiceSql $Sql) -split "`r?`n" | Where-Object { $_ -match '^FTR-' }) }
function Request-Many([string[]]$Numbers) {
    $accepted = [Collections.Generic.List[string]]::new()
    foreach ($number in $Numbers) {
        $r = Send-Api POST "/api/v1/invoices/$number/cancel" (Get-OperatorToken)
        $codes["$($r.Status)"] = 1 + [int]$codes["$($r.Status)"]
        if ($r.Status -eq 202) { $accepted.Add($number) }
    }
    , $accepted
}

$backupFile = $null; $backupAt = $null; $enoughAt = $null; $reached = 0; $cancelledThere = 0
while ($true) {
    $files = Get-BackupFiles
    if (-not $backupFile -and $files.Count -gt 0 -and $files[-1].Name -ne $lastBackup.Name) {
        $backupFile = $files[-1]; $backupAt = Get-BackupTime $backupFile
        Write-Line "  Yük sürerken alınan yedek: $($backupFile.Name)"
    }
    # İptaller: kuyruktaki, ERP'ye ulaşmış ve yedekten sonra alınıp ERP'ye ulaşmış faturalar.
    [void](Request-Many (Get-Numbers "SELECT i.invoice_number FROM invoices i WHERE i.customer_code = '$runId' AND i.status = 'Bekliyor' AND i.send_attempt_count = 0 AND $noCancel ORDER BY i.created_at DESC LIMIT 5"))
    [void](Request-Many (Get-Numbers "SELECT i.invoice_number FROM invoices i WHERE i.customer_code = '$runId' AND i.status IN $atErpStates AND $noCancel ORDER BY random() LIMIT 5"))
    if ($backupAt) {
        $iso = Get-Iso $backupAt
        $accepted = Request-Many (Get-Numbers "SELECT i.invoice_number FROM invoices i WHERE i.customer_code = '$runId' AND i.created_at >= '$iso' AND i.status IN $atErpStates AND $noCancel ORDER BY i.created_at LIMIT 20")
        $newRequested.AddRange([string[]]$accepted)
        $reached = [int](Invoke-InvoiceSql "SELECT count(*) FROM invoices i WHERE i.customer_code = '$runId' AND i.created_at >= '$iso' AND i.erp_reference IS NOT NULL")
        if ($newRequested.Count -gt 0) {
            $list = ($newRequested | ForEach-Object { "'$_'" }) -join ','
            $cancelledThere = [int](Get-SqlScalar "SELECT count(*) FROM cancellations WHERE invoice_number IN ($list)")
        }
        $sinceBackup = ([DateTimeOffset]::UtcNow - $backupAt).TotalMinutes
        if ($DeleteAfterSeconds -gt 0) {
            if (($sinceBackup * 60) -ge $DeleteAfterSeconds) { Write-Line ("  Yedekten {0:0.0} dk sonra: yedekten sonra alınıp ERP'ye ulaşan {1}, iptali ulaşan {2}" -f $sinceBackup, $reached, $cancelledThere); break }
            Start-Sleep -Seconds 3
            continue
        }
        if (-not $enoughAt -and $reached -ge $EnoughAtErp -and $cancelledThere -ge $EnoughCancelled) {
            $enoughAt = [DateTimeOffset]::UtcNow
            Write-Line ("  Yedekten {0:0.0} dk sonra: yedekten sonra alınıp ERP'ye ulaşan {1}, iptali ulaşan {2}; haberler için 30 sn daha" -f $sinceBackup, $reached, $cancelledThere)
        }
        if ($enoughAt -and ([DateTimeOffset]::UtcNow - $enoughAt).TotalSeconds -ge 30) { break }
        if ($sinceBackup -ge $MaxMinutesAfterBackup) { Write-Line "  $MaxMinutesAfterBackup dk doldu: ulaşan $reached, iptali ulaşan $cancelledThere"; break }
    }
    Start-Sleep -Seconds 3
}
Write-Line "  İptal isteklerinin cevapları: $(($codes.Keys | Sort-Object | ForEach-Object { "HTTP $_ x $($codes[$_])" }) -join ', ')"
Save-Report

Write-Line ''
Write-Line '3) Veritabanı siliniyor (container ve volume)'
$queueAtDeletion = Invoke-InvoiceSql "SELECT count(*) FROM erp_outbox WHERE status = 'Bekliyor'"
$waits = Invoke-InvoiceSql "SELECT count(*) || ' iptal, ortalama ' || round(avg(extract(epoch FROM o.processed_at - o.created_at))) || ' sn, en çok ' || round(max(extract(epoch FROM o.processed_at - o.created_at))) || ' sn' FROM erp_outbox o WHERE o.kind = 'İptal' AND o.status = 'Tamamlandı'"
Write-Line "  Silmeden hemen önce kuyruk $queueAtDeletion; tamamlanan iptallerin bekleme süresi: $waits"
$deletedAt = [DateTimeOffset]::UtcNow
Push-Location $RepoRoot
try {
    docker compose rm -sf invoice-db 2>&1 | Out-Null
    docker volume rm $Volume 2>&1 | ForEach-Object { Write-Line "  volume silindi: $_" }
    $logFile = Join-Path $OutputDir "$Name-servis-logu.txt"
    docker compose logs --no-color --no-log-prefix invoice-service 2>&1 | ForEach-Object { "$_" } | Set-Content $logFile -Encoding UTF8
}
finally { Pop-Location }
Write-Line "  Silindi: $(Get-Iso $deletedAt); yedekten bu yana $(Format-Duration ($deletedAt - $backupAt).TotalSeconds)"

Write-Line ''
Write-Line '4) Geri dönüş betiği'
$watch = [Diagnostics.Stopwatch]::StartNew()
Push-Location $RepoRoot
try { & $Bash scripts/restore-invoice-db.sh 2>&1 | ForEach-Object { Write-Line "    $_" } } finally { Pop-Location }
$restored = [DateTimeOffset]::UtcNow
Write-Line "  Betik: $(Format-Duration $watch.Elapsed.TotalSeconds)"
$deadline = (Get-Date).AddMinutes(5); $first = ''
while (-not $first -and (Get-Date) -lt $deadline) {
    $first = Invoke-InvoiceSql "SELECT to_char(min(created_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.MS') || '+00:00' FROM invoices WHERE created_at > '$(Get-Iso $deletedAt)'"
    if (-not $first) { Start-Sleep -Milliseconds 500 }
}
$firstAt = [DateTimeOffset]$first
Check ([bool]$first) "Silmeden sonra alınan ilk fatura: $first"
Write-Line "  Silmeden ilk 202'ye: $(Format-Duration ($firstAt - $deletedAt).TotalSeconds)"
Save-Report

Write-Line ''
Write-Line '5) Servis yük altında çalışmaya devam ediyor; kuyruğun erimesi'
$k6Out = Receive-Job $k6Job -Wait -AutoRemoveJob
$k6 = Get-Content (Join-Path $RepoRoot "load-test\results\$runId.json") -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Line "  k6: $($k6.requests) istek, $($k6.accepted) kabul (202), kabul edilmeyen $($k6.notAccepted), p95 $([Math]::Round($k6.durationMs.p95, 1)) ms"
$deadline = (Get-Date).AddMinutes(90)
do {
    $pending = [int](Invoke-InvoiceSql "SELECT count(*) FROM erp_outbox WHERE status = 'Bekliyor'")
    if ($pending -gt 0) { Start-Sleep -Seconds 10 }
} while ($pending -gt 0 -and (Get-Date) -lt $deadline)
$drainedAt = [DateTimeOffset]::UtcNow
Check ($pending -eq 0) "Kuyruk: $pending; silmeden kuyruğun erimesine $(Format-Duration ($drainedAt - $deletedAt).TotalSeconds)"
Write-Line '  Takılı sayılma süresi için 150 sn bekleniyor, sonra mutabakat'
Start-Sleep -Seconds 150
$run1 = Invoke-ReconciliationRetry
Check ($run1.status -eq 'Tamamlandı') "Mutabakat $($run1.id): $($run1.status), kontrol edilen $($run1.checkedCount), düzeltilen $($run1.fixedCount), raporlanan $($run1.reportedCount)"
Show-Rows 'Bu çalışmanın bulguları:' "SELECT finding_type, action, count(*) FROM reconciliation_findings WHERE run_id = $($run1.id) GROUP BY 1, 2 ORDER BY 1, 2"
Save-Report
Write-Line "  Tanınmayan Haber süresi için $WaitForUnknownMinutes dk bekleniyor (ayar değiştirilmedi)"
Start-Sleep -Seconds ($WaitForUnknownMinutes * 60)
$run2 = Invoke-ReconciliationRetry
Check ($run2.status -eq 'Tamamlandı') "Mutabakat $($run2.id): $($run2.status), kontrol edilen $($run2.checkedCount), düzeltilen $($run2.fixedCount), raporlanan $($run2.reportedCount)"
Show-Rows 'Bu çalışmanın bulguları:' "SELECT finding_type, action, count(*) FROM reconciliation_findings WHERE run_id = $($run2.id) GROUP BY 1, 2 ORDER BY 1, 2"
Save-Report

Write-Line ''
Write-Line '6) Çift fatura ve faturasından önce ulaşan iptal'
$erpRow = (Get-SqlScalar "SELECT count(DISTINCT invoice_number) || '|' || count(*) FROM invoices WHERE customer_code = '$runId'") -split '\|'
Write-Line "  ERP'de $($erpRow[0]) farklı fatura numarası, $($erpRow[1]) kayıt"
Check ($erpRow[0] -eq $erpRow[1]) "ERP'de birden fazla kaydı olan fatura numarası: $([int]$erpRow[1] - [int]$erpRow[0])"
$allDuplicates = Get-SqlScalar "SELECT count(*) FROM (SELECT invoice_number FROM invoices GROUP BY 1 HAVING count(*) > 1) d"
Check ($allDuplicates -eq '0') "ERP'nin bütününde çift numara: $allDuplicates"
$early = Get-SqlScalar "SELECT count(*) FROM cancellations c WHERE NOT EXISTS (SELECT 1 FROM invoices i WHERE i.invoice_number = c.invoice_number AND i.received_at < c.cancelled_at)"
Check ($early -eq '0') "Faturasının kaydından önce oluşan ya da faturası olmayan iptal kaydı: $early"
$earlyRequests = @(Get-SimulatorLog | Where-Object { "$_" -match 'ERP cancel invoice=\S+ status=404 reason=notRecorded' }).Count
Check ($earlyRequests -eq 0) "ERP'ye faturasından önce gelen iptal isteği (simülatör logu, status=404 reason=notRecorded): $earlyRequests"

Write-Line ''
Write-Line '7) Geri gelen, yalnız raporlanan, kaybolan'
$delIso = Get-Iso $deletedAt; $bakIso = Get-Iso $backupAt; $resIso = Get-Iso $restored
$log = Get-Content $logFile -Encoding UTF8
$acceptedLog = [Collections.Generic.HashSet[string]]::new(); $cancelLog = [Collections.Generic.HashSet[string]]::new()
foreach ($line in $log) {
    if ($line -match 'Invoice queued invoice=(FTR-\d+)') { [void]$acceptedLog.Add($Matches[1]) }
    elseif ($line -match 'Invoice cancellation queued invoice=(FTR-\d+)') { [void]$cancelLog.Add($Matches[1]) }
}
$inBackup = Get-RowSet (Invoke-InvoiceSql "SELECT invoice_number FROM invoices WHERE created_at < '$delIso'")
$cancelInBackup = Get-RowSet (Invoke-InvoiceSql "SELECT invoice_number FROM erp_outbox WHERE kind = 'İptal' AND created_at < '$delIso'")
$erpAll = Get-RowSet (Get-SqlScalar "SELECT invoice_number FROM invoices WHERE customer_code = '$runId'")
$erpAfterBackup = Get-RowSet (Get-SqlScalar "SELECT invoice_number FROM invoices WHERE customer_code = '$runId' AND received_at >= '$bakIso' AND received_at < '$delIso'")
$erpAfterReturn = Get-RowSet (Get-SqlScalar "SELECT invoice_number FROM invoices WHERE customer_code = '$runId' AND received_at >= '$delIso'")
$erpCancelled = Get-RowSet (Get-SqlScalar "SELECT c.invoice_number FROM cancellations c JOIN invoices i ON i.invoice_number = c.invoice_number WHERE i.customer_code = '$runId'")
$missingFindings = Get-RowSet (Invoke-InvoiceSql "SELECT DISTINCT invoice_number FROM reconciliation_findings WHERE finding_type = 'Serviste Yok'")
$missingCancelled = Get-RowSet (Invoke-InvoiceSql "SELECT DISTINCT invoice_number FROM reconciliation_findings WHERE finding_type = 'Serviste Yok' AND details LIKE '%iptal edilmiş%'")
$statusOf = @{}
foreach ($row in ((Invoke-InvoiceSql "SELECT invoice_number || '|' || status FROM invoices WHERE customer_code = '$runId'") -split "`r?`n")) { $p = $row -split '\|'; if ($p.Count -eq 2) { $statusOf[$p[0]] = $p[1] } }

Write-Line "  Servis logundan: silmeden önce kabul edilen $($acceptedLog.Count) fatura, $($cancelLog.Count) iptal isteği; yedekte $($inBackup.Count) fatura, $($cancelInBackup.Count) iptal satırı (dönüşten sonrakiler hariç created_at ile)"
$postInvoices = @($acceptedLog | Where-Object { -not $inBackup.Contains($_) })
$reportedInv = @($postInvoices | Where-Object { $erpAll.Contains($_) })
$lostInv = @($postInvoices | Where-Object { -not $erpAll.Contains($_) })
$backInv = @($erpAfterBackup | Where-Object { $inBackup.Contains($_) })
$backNotMoved = @($backInv | Where-Object { $statusOf[$_] -in 'Bekliyor', 'Başarısız' })
$backSentLater = @($erpAfterReturn | Where-Object { $inBackup.Contains($_) }).Count
Write-Line ''
Write-Line "  FATURA: yedekten sonra alınan $($postInvoices.Count)"
Write-Line "    Geri gelen: yedekte Bekliyor, yedekten sonra ERP'ye ulaşmış, yeniden gönderilmeden ilerleyen $($backInv.Count) (Bekliyor/Başarısız kalan $($backNotMoved.Count))"
Write-Line "    Yalnız raporlanan: ERP'de var, serviste yok $($reportedInv.Count)"
Write-Line "    Kaybolan: yedekte de ERP'de de yok $($lostInv.Count)"
Write-Line "    (Karşılaştırma için: yedekte Bekliyor, ERP'ye dönüşten sonra giden $backSentLater)"
$notFound = @($reportedInv | Where-Object { -not $missingFindings.Contains($_) }).Count
Check ($notFound -eq 0) "ERP'de olup serviste olmayan $($reportedInv.Count) kaydın Serviste Yok bulgusu olmayanı: $notFound (bulgu sayısı $($missingFindings.Count))"
$extraFindings = @($missingFindings | Where-Object { $_ -match '^FTR-' -and -not $postInvoices.Contains($_) }).Count
Check ($extraFindings -eq 0) "Yedekten sonra alınmadığı halde Serviste Yok bulgusu olan: $extraFindings"
Check ($backNotMoved.Count -eq 0) "ERP'ye ulaşmış olup Bekliyor/Başarısız kalan: $($backNotMoved.Count)"

$postCancels = @($cancelLog | Where-Object { -not $cancelInBackup.Contains($_) })
$cancelBack = @($postCancels | Where-Object { $erpCancelled.Contains($_) -and $inBackup.Contains($_) })
$cancelBackDone = @($cancelBack | Where-Object { $statusOf[$_] -eq 'İptal Edildi' }).Count
$cancelReported = @($postCancels | Where-Object { $erpCancelled.Contains($_) -and -not $inBackup.Contains($_) })
$cancelReportedWithText = @($cancelReported | Where-Object { $missingCancelled.Contains($_) }).Count
$cancelLost = @($postCancels | Where-Object { -not $erpCancelled.Contains($_) })
$lostThenSent = @($cancelLost | Where-Object { $erpAll.Contains($_) -and $inBackup.Contains($_) }).Count
$lostWithInvoice = @($cancelLost | Where-Object { -not $inBackup.Contains($_) }).Count
Write-Line ''
Write-Line "  İPTAL İSTEĞİ: yedekten sonra 202 alan $($postCancels.Count)"
Write-Line "    Geri gelen: ERP'ye ulaşmış, faturası yedekte $($cancelBack.Count) (serviste İptal Edildi olan $cancelBackDone)"
Write-Line "    Yalnız raporlanan: ERP'ye ulaşmış, faturası yedekte yok $($cancelReported.Count) (bulguda 'ERP'de iptal edilmiş' yazan $cancelReportedWithText)"
Write-Line "    Kaybolan: ERP'ye ulaşmamış $($cancelLost.Count) (faturası yedekte olup ERP'ye giden $lostThenSent; faturası yedekte olmayan $lostWithInvoice)"
Check ($cancelBackDone -eq $cancelBack.Count) "ERP'de iptal edilip serviste İptal Edildi olmayan (faturası yedekte): $($cancelBack.Count - $cancelBackDone)"
Check ($cancelReportedWithText -eq $cancelReported.Count) "ERP'de iptal edilmiş olup bulgusu bunu yazmayan: $($cancelReported.Count - $cancelReportedWithText)"

$serviceEvents = Get-RowSet (Invoke-InvoiceSql "SELECT event_id FROM erp_webhook_events")
$unknownIgnored = Get-RowSet (Invoke-InvoiceSql "SELECT DISTINCT invoice_number FROM reconciliation_findings WHERE finding_type = 'Tanınmayan Haber'")
$rows = (Get-SqlScalar ("SELECT DISTINCT d.event_id || '|' || d.invoice_number || '|' || d.status FROM webhook_deliveries d JOIN invoices i ON i.id = d.invoice_id " +
    "WHERE i.customer_code = '$runId' AND d.kind NOT IN ('Fake', 'Replay') AND d.status <> 'Skipped' AND d.first_sent_at >= '$bakIso' AND d.first_sent_at < '$resIso'")) -split "`r?`n"
$eventsBackRow = 0; $eventsBackEffect = 0; $eventsReported = 0; $eventsLost = 0; $seen = @{}
foreach ($row in $rows) {
    $p = $row -split '\|'; if ($p.Count -lt 3 -or $seen.ContainsKey($p[0])) { continue }; $seen[$p[0]] = 1
    if ($inBackup.Contains($p[1])) { if ($serviceEvents.Contains($p[0])) { $eventsBackRow++ } else { $eventsBackEffect++ } }
    elseif ($serviceEvents.Contains($p[0])) { $eventsReported++ }
    else { $eventsLost++ }
}
$stuck = Invoke-InvoiceSql "SELECT count(*) FROM invoices WHERE customer_code = '$runId' AND status IN ('Gönderildi', 'İşleme Alındı')"
Write-Line ''
Write-Line "  ERP HABERİ: yedekten dönüşe kadar gönderilen $($seen.Count)"
Write-Line "    Geri gelen: faturası yedekte, haberi tekrar gönderimle yeniden kayıtlı $eventsBackRow; kaydı yok, etkisi mutabakatla gelen $eventsBackEffect"
Write-Line "    Yalnız raporlanan: faturası yedekte yok, haberi serviste (Tanınmayan Haber) $eventsReported (bulgulu fatura $($unknownIgnored.Count))"
Write-Line "    Kaybolan: faturası yedekte yok, haberin serviste kaydı da yok $eventsLost (kararı ERP'de duruyor)"
Show-Rows 'Yük faturalarının son durumu:' "SELECT status, count(*) FROM invoices WHERE customer_code = '$runId' GROUP BY 1 ORDER BY 1"
Write-Line "  Son durumda hâlâ Gönderildi / İşleme Alındı: $stuck (ERP karar vermeyenler dahil)"
Show-Rows 'Bütün bulgular:' "SELECT finding_type, action, count(*) FROM reconciliation_findings GROUP BY 1, 2 ORDER BY 1, 2"

Write-Line ''
Write-Line '8) Veri kaybı ve geri dönüş süresi'
Write-Line "  Dönülen yedek: $($backupFile.Name); yedekten silmeye $(Format-Duration ($deletedAt - $backupAt).TotalSeconds) (yedek aralığı $([int]($IntervalSeconds / 60)) dk + yedek süresi)"
Write-Line "  Yedekten sonra alınan $($postInvoices.Count) faturadan $($lostInv.Count) tamamen, $($reportedInv.Count) yalnız raporlanarak kayıp"
Write-Line "  Silmeden ilk 202'ye $(Format-Duration ($firstAt - $deletedAt).TotalSeconds) (hedef 15 dk; fark etme ve karar süresi yok)"
Write-Line "  Silmeden kuyruğun erimesine $(Format-Duration ($drainedAt - $deletedAt).TotalSeconds)"
Write-Line '  Yedek servisi logu:'
Show-BackupLog
Write-Line "  Yedek klasörü: $((Get-BackupFiles).Count) dosya, en büyüğü $([Math]::Round(((Get-BackupFiles | Measure-Object Length -Maximum).Maximum) / 1MB, 2)) MB"
$permissionErrors = @(& { Push-Location $RepoRoot; docker compose logs --since 3h invoice-service erp-simulator 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'permission denied|42501:' }; Pop-Location })
Check ($permissionErrors.Count -eq 0) "Yetki hatası (dönüşten sonra invoice_app): $($permissionErrors.Count)"
Save-Report
