# Yük testinin önce/sonra tablosu (kontrol listesi 3). Yük testi bittikten sonra çalıştırılır; kuyruk henüz boşalmadıysa
# boşalana kadar bekler:
#   .\manual-tests\gun10\2-yuk-olcum.ps1 -RunId GUN10-once-20261012-100000 -Label once -Volume once
# Simülatör yük testiyle bu ölçüm arasında yeniden başlatılmamalı: logları container'la birlikte gider.
#
# Satırların kaynağı:
#   Kuyruğa girişten Gönderildi'ye süre   erp_outbox: processed_at - created_at; yalnızca Tamamlandı olanlar. p50 ve p95
#                                         bu sürelerin yüzdelikleri (k6'nın istek süresi değil), en uzun ise en büyüğü.
#   Tekrar denenen / ilk denemede         aynı süre; tekrar denenen = attempt_count > 1, ilk denemede = attempt_count = 1.
#   Kuyruğun boşalma süresi               ilk faturanın kuyruğa girişinden son kaydın bittiği ana (processed_at).
#   Hız sınırı 429 oranı                  simülatör logu: reason=rateLimited / simülatöre gelen toplam POST.
#   Kaybolan fatura                       k6'nın 202 aldığı ama serviste olmayan + serviste Tamamlandı olup ERP'de kaydı olmayan.
#   Birden fazla kayıt                    ERP veritabanında bu müşteri kodlu, aynı numaralı birden fazla kayıt.
# Sonuç tablosu manual-tests\output\gun10-<Label>-sonuc.md'ye yazılır.
param(
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][string]$Volume,
    [int]$TimeoutMinutes = 120
)

. "$PSScriptRoot\_common.ps1"
Use-Gun10Volumes $Volume

Write-Title "Yük testi sonucu: $RunId ($Label)"

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
    if ($pending -gt 0) { Start-Sleep -Seconds 60 }
} while ($pending -gt 0 -and (Get-Date) -lt $deadline)
if ($pending -gt 0) { throw "$TimeoutMinutes dakikada kuyruk boşalmadı ($pending bekliyor)." }

# --- Servis veritabanı ------------------------------------------------------------------------------------------------
$ts = "'YYYY-MM-DD HH24:MI:SS.MS'"
$row = @(Get-ServiceRows ("SELECT count(*) || '|' || count(*) FILTER (WHERE o.status = 'Tamamlandı') || '|' || " +
    "count(*) FILTER (WHERE o.status = 'Başarısız') || '|' || " +
    "to_char(min(o.created_at) AT TIME ZONE 'UTC', $ts) || '|' || to_char(max(o.processed_at) AT TIME ZONE 'UTC', $ts) || '|' || " +
    "extract(epoch FROM max(o.processed_at) - min(o.created_at))::numeric(10,1) $runJoin;"))[0] -split '\|'
$created = [int]$row[0]; $completed = [int]$row[1]; $failed = [int]$row[2]
$firstAt = $row[3]; $lastAt = $row[4]; $drainSeconds = [double]$row[5]

$waits = @(Get-ServiceRows ("WITH w AS (SELECT o.attempt_count, extract(epoch FROM o.processed_at - o.created_at) AS s " +
    "$runJoin AND o.status = 'Tamamlandı') " +
    "SELECT count(*) || '|' || round((percentile_cont(0.5) WITHIN GROUP (ORDER BY s))::numeric, 1) || '|' || " +
    "round((percentile_cont(0.95) WITHIN GROUP (ORDER BY s))::numeric, 1) || '|' || round(max(s)::numeric, 1) || '|' || " +
    "count(*) FILTER (WHERE attempt_count > 1) || '|' || coalesce(round(max(s) FILTER (WHERE attempt_count > 1)::numeric, 1)::text, '0') || '|' || " +
    "count(*) FILTER (WHERE attempt_count = 1) || '|' || coalesce(round(max(s) FILTER (WHERE attempt_count = 1)::numeric, 1)::text, '0') FROM w;"))[0] -split '\|'
$p50 = [double]$waits[1]; $p95 = [double]$waits[2]; $maxAll = [double]$waits[3]
$retriedCount = [int]$waits[4]; $maxRetried = [double]$waits[5]
$firstCount = [int]$waits[6]; $maxFirst = [double]$waits[7]
$longestInvoice = @(Get-ServiceRows ("SELECT o.invoice_number || ' (' || o.attempt_count || ' deneme)' $runJoin AND o.status = 'Tamamlandı' " +
    "ORDER BY o.processed_at - o.created_at DESC LIMIT 1;"))[0]
$numbers = [Collections.Generic.HashSet[string]]::new([string[]]@(Get-ServiceRows "SELECT invoice_number FROM invoices WHERE customer_code = '$RunId';" | Where-Object { $_ -match '^FTR-' }))
$completedNumbers = @(Get-ServiceRows "SELECT o.invoice_number $runJoin AND o.status = 'Tamamlandı';" | Where-Object { $_ -match '^FTR-' })

# --- ERP veritabanı ---------------------------------------------------------------------------------------------------
$dupes = [int]@(Get-ErpRows "SELECT count(*) FROM (SELECT invoice_number FROM invoices WHERE customer_code = '$RunId' GROUP BY 1 HAVING count(*) > 1) d;")[0]
$erpNumbers = [Collections.Generic.HashSet[string]]::new([string[]]@(Get-ErpRows "SELECT DISTINCT invoice_number FROM invoices WHERE customer_code = '$RunId';" | Where-Object { $_ -match '^FTR-' }))
$completedNotAtErp = @($completedNumbers | Where-Object { -not $erpNumbers.Contains($_) })
$lost = ($k6.accepted - $created) + $completedNotAtErp.Count

# --- Simülatör logu ---------------------------------------------------------------------------------------------------
Write-Step 'Simülatör logu okunuyor'
$from = ([datetime]$firstAt).AddSeconds(-1).ToString('yyyy-MM-dd HH:mm:ss')
$to = ([datetime]$lastAt).AddSeconds(1).ToString('yyyy-MM-dd HH:mm:ss')
$posts = 0; $rateLimited = 0
foreach ($line in (Get-SimulatorLogSince $from)) {
    $line = "$line"
    if ($line -match 'ERP request #\d+ invoice=(\S+) behavior=') {
        if ($numbers.Contains($Matches[1])) { $posts++ }
    }
    elseif ($line -match 'reason=rateLimited') {
        if ($line.Substring(0, 19) -le $to) { $posts++; $rateLimited++ }
    }
}
$rlRatio = if ($posts) { 100.0 * $rateLimited / $posts } else { 0 }

# --- Tablo ------------------------------------------------------------------------------------------------------------
$git = (& git -C $RepoRoot rev-parse --short HEAD) + $(if (& git -C $RepoRoot status --short) { ' (+ çalışma ağacında değişiklik)' } else { '' })
$inv = [Globalization.CultureInfo]::GetCultureInfo('tr-TR')
function Row([string]$Name, [double]$Seconds) { [pscustomobject]@{ Ölçü = $Name; Değer = "$(Format-Duration $Seconds) ($($Seconds.ToString('N1', $inv)) sn)" } }
$table = @(
    (Row 'Kuyruğa girişten Gönderildi''ye kadar geçen süre p50' $p50),
    (Row 'Kuyruğa girişten Gönderildi''ye kadar geçen süre p95' $p95),
    [pscustomobject]@{ Ölçü = 'Kuyruğa girişten Gönderildi''ye kadar geçen en uzun süre'; Değer = "$(Format-Duration $maxAll) ($($maxAll.ToString('N1', $inv)) sn) - $longestInvoice" },
    [pscustomobject]@{ Ölçü = 'Tekrar denenen faturalarda en uzun süre'; Değer = "$(Format-Duration $maxRetried) ($($maxRetried.ToString('N1', $inv)) sn); $retriedCount fatura" },
    [pscustomobject]@{ Ölçü = 'İlk denemede gönderilen faturalarda en uzun süre'; Değer = "$(Format-Duration $maxFirst) ($($maxFirst.ToString('N1', $inv)) sn); $firstCount fatura" },
    [pscustomobject]@{ Ölçü = 'Kuyruğun boşalma süresi'; Değer = "$(Format-Duration $drainSeconds) ($($drainSeconds.ToString('N1', $inv)) sn; $firstAt - $lastAt UTC)" },
    [pscustomobject]@{ Ölçü = 'Hız sınırından kaynaklanan 429 oranı'; Değer = ('%{0} ({1} / {2} POST)' -f $rlRatio.ToString('N2', $inv), $rateLimited, $posts) },
    [pscustomobject]@{ Ölçü = 'Kaybolan fatura (0 olmalı)'; Değer = "$lost (202 alıp serviste olmayan $($k6.accepted - $created), Tamamlandı olup ERP'de olmayan $($completedNotAtErp.Count))" },
    [pscustomobject]@{ Ölçü = 'Simülatörde birden fazla kaydı olan fatura (0 olmalı)'; Değer = "$dupes" }
)
Write-Step 'Sonuç tablosu'
$table | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host

$md = @("# Yük testi $RunId ($Label)", '',
    "Adresler: $($k6.baseUrls -join ', '); $($k6.rate)/sn, $($k6.duration). Kod: $git. Volume: $Volume.",
    "k6: $($k6.requests) istek, $($k6.accepted) kabul; serviste $created fatura (Tamamlandı $completed, Başarısız $failed).", '',
    '| Ölçü | Değer |', '|---|---|')
$md += $table | ForEach-Object { "| $($_.Ölçü) | $($_.Değer) |" }
$md | Set-Content (Join-Path $OutputDir "gun10-$Label-sonuc.md") -Encoding UTF8
Write-Host "  Tablo: manual-tests\output\gun10-$Label-sonuc.md" -ForegroundColor DarkGray

$checks = @(
    (Write-DbVerdict 'kaybolan fatura 0' "$lost" ($lost -eq 0)),
    (Write-DbVerdict 'simülatörde birden fazla kaydı olan fatura 0' "$dupes" ($dupes -eq 0))
)
Write-Result (@($checks | Where-Object { -not $_ }).Count -eq 0) "Yük testi $RunId ($Label)"
