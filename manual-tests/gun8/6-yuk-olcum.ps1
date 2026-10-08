# Yük testinin sonuç tablosu (kontrol listesi 2 ve 3). Yük testi bittikten ve kuyruk boşaldıktan sonra çalıştırılır:
#   .\manual-tests\gun8\6-yuk-olcum.ps1 -RunId LOAD-20261008T120000
# RunId, yük testinin müşteri kodu (load-test/results/<RunId>.json). Kuyruk henüz boşalmadıysa boşalana kadar bekler.
# Simülatör yük testiyle bu ölçüm arasında yeniden başlatılmamalı: logları container'la birlikte gider.
#
# Satırların kaynağı:
#   Gönderilen fatura        k6'nın 202 aldığı istek; servis veritabanında bu müşteri kodlu fatura; ERP'ye ulaşan.
#   Boşalma süresi           ilk faturanın oluşturulmasından (ilk istek) son outbox kaydının bittiği ana (processed_at).
#   Gönderim hızı            simülatör logu: saniye saniye gelen POST (hız sınırından geçen + hız sınırı 429'u);
#                            ortalama = POST / (ilk POST'tan son POST'a saniye), en yüksek = en yoğun saniye.
#   Hız sınırı 429 oranı     simülatör logundaki reason=rateLimited / toplam POST.
#   p50, p95, p99            k6 (load-test/results/<RunId>.json).
#   En uzun bekleme          outbox: processed_at - created_at'in en büyüğü (kuyruğa girişten bitene kadar).
#   Haberlerden 503 oranı    simülatör logu: bu faturaların haber denemeleri ("Webhook send ... http=503") / tüm denemeler.
#   Kaybolan fatura          k6'nın 202 aldığı ama serviste olmayan + serviste Tamamlandı olup ERP'de kaydı olmayan.
#   Birden fazla kayıt       ERP veritabanında bu müşteri kodlu, aynı numaralı birden fazla kayıt.
# Saniye saniye POST tablosu manual-tests\output\<RunId>-saniye.csv'ye, sonuç tablosu <RunId>-sonuc.md'ye yazılır.
param([Parameter(Mandatory)][string]$RunId, [int]$TimeoutMinutes = 40)

. "$PSScriptRoot\_common.ps1"

Write-Title "Yük testi sonucu: $RunId"

$k6File = Join-Path $RepoRoot "load-test\results\$RunId.json"
if (-not (Test-Path $k6File)) { throw "Yük testi sonuç dosyası yok: $k6File" }
$k6 = Get-Content $k6File -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host "  k6: $($k6.requests) istek, $($k6.accepted) kabul; adresler: $($k6.baseUrls -join ', ')" -ForegroundColor DarkGray

$runJoin = "FROM erp_outbox o JOIN invoices i ON i.invoice_number = o.invoice_number WHERE i.customer_code = '$RunId'"
Write-Step 'Kuyruğun boşalması bekleniyor'
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
do {
    $pending = [int]@(Get-ServiceRows "SELECT count(*) $runJoin AND o.status = 'Bekliyor';")[0]
    Write-Host "  $(Get-Date -Format 'HH:mm:ss') kuyrukta $pending" -ForegroundColor DarkGray
    if ($pending -gt 0) { Start-Sleep -Seconds 30 }
} while ($pending -gt 0 -and (Get-Date) -lt $deadline)
if ($pending -gt 0) { throw "$TimeoutMinutes dakikada kuyruk boşalmadı ($pending bekliyor)." }

# --- Servis veritabanı ------------------------------------------------------------------------------------------------
$ts = "'YYYY-MM-DD HH24:MI:SS.MS'"
$row = @(Get-ServiceRows ("SELECT count(*) || '|' || count(*) FILTER (WHERE o.status = 'Tamamlandı') || '|' || " +
    "count(*) FILTER (WHERE o.status = 'Başarısız') || '|' || " +
    "to_char(min(o.created_at) AT TIME ZONE 'UTC', $ts) || '|' || to_char(max(o.processed_at) AT TIME ZONE 'UTC', $ts) || '|' || " +
    "extract(epoch FROM max(o.processed_at) - min(o.created_at))::numeric(10,1) || '|' || " +
    "extract(epoch FROM max(o.processed_at - o.created_at))::numeric(10,1) || '|' || " +
    "extract(epoch FROM avg(o.processed_at - o.created_at))::numeric(10,1) $runJoin;"))[0] -split '\|'
$created = [int]$row[0]; $completed = [int]$row[1]; $failed = [int]$row[2]
$firstAt = $row[3]; $lastAt = $row[4]; $drainSeconds = [double]$row[5]; $longestWait = [double]$row[6]; $avgWait = [double]$row[7]
$longestInvoice = @(Get-ServiceRows ("SELECT o.invoice_number || ' (' || o.attempt_count || ' deneme)' $runJoin " +
    "ORDER BY o.processed_at - o.created_at DESC LIMIT 1;"))[0]
$numbers = [Collections.Generic.HashSet[string]]::new([string[]]@(Get-ServiceRows "SELECT invoice_number FROM invoices WHERE customer_code = '$RunId';" | Where-Object { $_ -match '^FTR-' }))
$completedNumbers = @(Get-ServiceRows "SELECT o.invoice_number $runJoin AND o.status = 'Tamamlandı';" | Where-Object { $_ -match '^FTR-' })

# --- ERP veritabanı ---------------------------------------------------------------------------------------------------
$erp = @(Get-ErpRows ("SELECT count(DISTINCT invoice_number) || '|' || count(*) FROM invoices WHERE customer_code = '$RunId';"))[0] -split '\|'
$erpInvoices = [int]$erp[0]; $erpRecords = [int]$erp[1]
$dupes = [int]@(Get-ErpRows "SELECT count(*) FROM (SELECT invoice_number FROM invoices WHERE customer_code = '$RunId' GROUP BY 1 HAVING count(*) > 1) d;")[0]
$erpNumbers = [Collections.Generic.HashSet[string]]::new([string[]]@(Get-ErpRows "SELECT DISTINCT invoice_number FROM invoices WHERE customer_code = '$RunId';" | Where-Object { $_ -match '^FTR-' }))
$completedNotAtErp = @($completedNumbers | Where-Object { -not $erpNumbers.Contains($_) })
$lost = ($k6.accepted - $created) + $completedNotAtErp.Count

# --- Simülatör logu ---------------------------------------------------------------------------------------------------
Write-Step 'Simülatör logu okunuyor'
$from = ([datetime]$firstAt).AddSeconds(-1).ToString('yyyy-MM-dd HH:mm:ss')
$to = ([datetime]$lastAt).AddSeconds(1).ToString('yyyy-MM-dd HH:mm:ss')
$posts = [Collections.Generic.List[string]]::new(); $rateLimited = 0; $busy = 0
$hooks = 0; $hooks503 = 0; $hooksNoAnswer = 0; $hookMaxMs = 0
foreach ($line in (Get-SimulatorLogSince $from)) {
    $line = "$line"
    if ($line -match 'ERP request #\d+ invoice=(\S+) behavior=') {
        if ($numbers.Contains($Matches[1])) { $posts.Add($line.Substring(0, 19)); if ($line -match 'reason=busy') { $busy++ } }
    }
    elseif ($line -match 'reason=rateLimited') {
        if ($line.Substring(0, 19) -le $to) { $posts.Add($line.Substring(0, 19)); $rateLimited++ }
    }
    elseif ($line -match 'Webhook send event=\S+ type=\S+ invoice=(\S+) .* http=(\S+) .* elapsed=(\d+)ms') {
        if ($numbers.Contains($Matches[1])) {
            $hooks++
            if ($Matches[2] -eq '503') { $hooks503++ } elseif ($Matches[2] -eq '-') { $hooksNoAnswer++ }
            if ([int]$Matches[3] -gt $hookMaxMs) { $hookMaxMs = [int]$Matches[3] }
        }
    }
}
$perSecond = @($posts | Group-Object | Sort-Object Name | ForEach-Object { [pscustomobject]@{ Saniye = $_.Name; POST = $_.Count } })
$perSecond | Export-Csv (Join-Path $OutputDir "$RunId-saniye.csv") -NoTypeInformation -Encoding UTF8
$maxRate = ($perSecond | Measure-Object POST -Maximum).Maximum
$postSpan = ([datetime]$perSecond[-1].Saniye - [datetime]$perSecond[0].Saniye).TotalSeconds + 1
$avgRate = $posts.Count / $postSpan
$rlRatio = if ($posts.Count) { 100.0 * $rateLimited / $posts.Count } else { 0 }
$hookRatio = if ($hooks) { 100.0 * $hooks503 / $hooks } else { 0 }

Write-Step 'Saniye başına POST dağılımı (simülatör logu)'
$perSecond | Group-Object POST | Sort-Object { [int]$_.Name } | ForEach-Object { Write-Host ("    {0,2} POST: {1,4} saniye" -f $_.Name, $_.Count) }

$limitLine = Get-SimulatorLog | Where-Object { $_ -match 'Rate limit: \d+' } | Select-Object -Last 1
$limit = if ($limitLine -match 'Rate limit: (\d+)') { [int]$Matches[1] } else { throw 'Hız sınırı log satırı bulunamadı.' }

# --- Tablo ------------------------------------------------------------------------------------------------------------
function Sec([double]$s) { $t = [TimeSpan]::FromSeconds($s); if ($t.TotalHours -ge 1) { '{0} sa {1} dk {2} sn' -f [int][math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds } else { '{0} dk {1} sn' -f $t.Minutes, $t.Seconds } }
$inv = [Globalization.CultureInfo]::GetCultureInfo('tr-TR')
$d = $k6.durationMs
$table = @(
    [pscustomobject]@{ Ölçü = 'Gönderilen fatura'; Değer = "$($k6.accepted) (k6 202); serviste $created; ERP'ye ulaşan $completed, Başarısız $failed" },
    [pscustomobject]@{ Ölçü = 'Kuyruğun boşalma süresi (ilk istekten itibaren)'; Değer = "$(Sec $drainSeconds) ($firstAt - $lastAt UTC)" },
    [pscustomobject]@{ Ölçü = 'Ortalama ve en yüksek gönderim hızı (saniyede)'; Değer = ('ortalama {0} POST/sn, en yüksek {1} POST/sn ({2} POST, {3} sn); ERP''ye ulaşan ortalama {4}/sn' -f $avgRate.ToString('N1', $inv), $maxRate, $posts.Count, $postSpan, ($completed / $drainSeconds).ToString('N1', $inv)) },
    [pscustomobject]@{ Ölçü = 'Hız sınırından kaynaklanan 429 oranı'; Değer = ('%{0} ({1} / {2}); Meşgul 429 ayrıca {3}' -f $rlRatio.ToString('N2', $inv), $rateLimited, $posts.Count, $busy) },
    [pscustomobject]@{ Ölçü = 'POST /api/v1/invoices cevap süresi p50, p95, p99'; Değer = ('{0} / {1} / {2} ms (en uzun {3} ms)' -f $d.p50.ToString('N1', $inv), $d.p95.ToString('N1', $inv), $d.p99.ToString('N1', $inv), $d.max.ToString('N1', $inv)) },
    [pscustomobject]@{ Ölçü = 'Kuyruktaki en uzun bekleme süresi'; Değer = "$(Sec $longestWait) ($longestInvoice); ortalama $(Sec $avgWait)" },
    [pscustomobject]@{ Ölçü = 'Haberlerden 503 alanların oranı'; Değer = ('%{0} ({1} / {2} deneme); cevapsız {3}, en uzun cevap {4} ms' -f $hookRatio.ToString('N2', $inv), $hooks503, $hooks, $hooksNoAnswer, $hookMaxMs) },
    [pscustomobject]@{ Ölçü = 'Kaybolan fatura'; Değer = "$lost (202 alıp serviste olmayan $($k6.accepted - $created), Tamamlandı olup ERP'de olmayan $($completedNotAtErp.Count))" },
    [pscustomobject]@{ Ölçü = 'Simülatörde birden fazla kaydı olan fatura'; Değer = "$dupes (ERP: $erpInvoices fatura, $erpRecords kayıt)" }
)
Write-Step 'Sonuç tablosu'
$table | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host

$md = @("# Yük testi $RunId", '', "Adresler: $($k6.baseUrls -join ', '); $($k6.rate)/sn, $($k6.duration).", '', '| Ölçü | Değer |', '|---|---|')
$md += $table | ForEach-Object { "| $($_.Ölçü) | $($_.Değer) |" }
$md | Set-Content (Join-Path $OutputDir "$RunId-sonuc.md") -Encoding UTF8
Write-Host "  Tablo: manual-tests\output\$RunId-sonuc.md; saniye saniye: $RunId-saniye.csv" -ForegroundColor DarkGray

$checks = @(
    (Write-DbVerdict "hız sınırı 429'u %5'in altında" ('%{0}' -f $rlRatio.ToString('N2', $inv)) ($rlRatio -lt 5)),
    (Write-DbVerdict "hiçbir saniyede $limit POST'tan fazla yok" "en çok $maxRate" ($maxRate -le $limit)),
    (Write-DbVerdict 'POST p95 200 ms altında' ('{0} ms' -f $d.p95.ToString('N1', $inv)) ($d.p95 -lt 200)),
    (Write-DbVerdict 'kaybolan fatura 0' "$lost" ($lost -eq 0)),
    (Write-DbVerdict 'simülatörde birden fazla kaydı olan fatura 0' "$dupes" ($dupes -eq 0))
)
Write-Result (@($checks | Where-Object { -not $_ }).Count -eq 0) "Yük testi $RunId"
