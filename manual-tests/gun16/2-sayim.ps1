# Kontrol listesi 3'ün sayımı: uzun yük testinin faturalarından hangilerinin izi Jaeger'da saklandı; her faturanın
# oluşturma isteği de fatura numarasıyla bulunuyor mu.
#   .\manual-tests\gun16\2-sayim.ps1 -RunId GUN16-uzun-20261020-120000
# 1-uzun-yuk.ps1 koşunun sonunda bunu çağırır; ayrıca çalıştırılırsa aynı koşu yeniden sayılır (yığın o koşunun
# volume'leriyle açık ve Jaeger o koşudan beri yeniden başlamamış olmalı).
#
# Gruplar Fatura Servisi veritabanından (customer_code = koşu kimliği):
#   Sorunsuz: Başarısız değil ve 3'ten az denendi. Sorunlu: en az 3 kez denendi ya da Başarısız.
# Saklanan sorunsuz oranı tek değerdir; gönderimin bittiği ana (erp_outbox.processed_at) göre 10 dakikalık dilimleri de
# yazılır. Testin başlangıcı koşunun ilk faturasının oluşturulduğu andır.
# Karar süresinin yetip yetmediği: izi saklanan her faturada kuyruktan ilk alınmadan (outbox.queue_wait'in bitişi) Sent
# sonuçlu denemenin bitişine kadar geçen süre. Bu süre karar süresinden uzun olan sorunsuz fatura, karar anında henüz
# gönderilmemiş olduğu için ihtiyat kuralıyla saklanmıştır (örnekleme yüzdesine girmeden).
# Jaeger'da invoice.number ile bulunan trace'ler türüne göre ayrılır (_common.ps1, Split-InvoiceTraces):
#   Fatura izi: worker kaydı kuyruktan ilk aldığında başlayan iz. "İzi saklanan" = fatura izi bulunan fatura.
#   Oluşturma izi: oluşturma isteğinin kendi izi; ayrı sayılır.
# Fatura izinin tam olup olmadığı da bakılır: kuyruk beklemesi adımı (outbox.queue_wait), 1..send_attempt_count numaralı
# bütün denemeler ve veritabanındaki her ERP haberi.
# Çıktı output\gun16-2-<Name>-sayim.txt ve -faturalar.csv (fatura başına sonuç).
param([Parameter(Mandatory)][string]$RunId, [string]$Name = 'uzun')

. "$PSScriptRoot\_common.ps1"
Use-Gun10Volumes "gun16-$Name"

$prefix = "gun16-2-$Name"
$out = Join-Path $OutputDir "$prefix-sayim.txt"
$report = [Collections.Generic.List[string]]::new()
function Write-Line([string]$Text) { Write-Host $Text; $report.Add($Text) }

Write-Step 'Faturalar veritabanından okunuyor'
# Zamanlar epoch saniyesi (ondalıklı): psql'e giden sorguda tırnak ve biçim karakterleri kullanılmaz.
$inv = [Globalization.CultureInfo]::InvariantCulture
function ConvertFrom-Epoch([string]$Text) {
    if (-not $Text) { return $null }
    [DateTimeOffset]::FromUnixTimeMilliseconds([long]([double]::Parse($Text, $inv) * 1000))
}
$rows = @(Get-ServiceRows @"
SELECT i.invoice_number, i.send_attempt_count, i.status,
       (SELECT count(*) FROM erp_webhook_events e WHERE e.invoice_number = i.invoice_number),
       extract(epoch FROM i.created_at)::numeric(16,3),
       (SELECT extract(epoch FROM max(o.processed_at))::numeric(16,3) FROM erp_outbox o WHERE o.invoice_number = i.invoice_number)
FROM invoices i WHERE i.customer_code = '$RunId' ORDER BY i.invoice_number;
"@ | ForEach-Object {
    $c = $_.Split('|')
    $created = ConvertFrom-Epoch $c[4]
    $processed = ConvertFrom-Epoch $c[5]
    [pscustomobject]@{ Number = $c[0]; Attempts = [int]$c[1]; Status = $c[2]; Events = [int]$c[3]; Created = $created
        Processed = $processed; WaitMinutes = if ($processed) { ($processed - $created).TotalMinutes } else { $null } }
})
if ($rows.Count -eq 0) { throw "$RunId koşusunun faturası yok." }
Write-Host "  $($rows.Count) fatura"

# Jaeger'da faturanın izleri: arama sonucu trace'leri span'leriyle birlikte döner, ayrıca trace okunmaz.
Write-Step "Jaeger'da her faturanın izleri aranıyor"
$from = ($rows | Measure-Object -Property Created -Minimum).Minimum.AddMinutes(-1)
$to = [DateTimeOffset]::UtcNow
$watch = [Diagnostics.Stopwatch]::StartNew()
$i = 0
foreach ($r in $rows) {
    $i++
    if ($i % 1000 -eq 0) { Write-Host ("  {0} / {1} ({2})" -f $i, $rows.Count, (Format-Duration $watch.Elapsed.TotalSeconds)) -ForegroundColor DarkGray }
    $tags = [Uri]::EscapeDataString((@{ 'invoice.number' = $r.Number } | ConvertTo-Json -Compress))
    $traces = @((Get-JaegerJsonRetry "$JaegerUrl/api/traces?service=invoice-service&tags=$tags&start=$(ConvertTo-JaegerTime $from)&end=$(ConvertTo-JaegerTime $to)&limit=100").data)
    $split = Split-InvoiceTraces $traces
    $r | Add-Member Traces @($split.Invoice | ForEach-Object { $_.traceID } | Sort-Object -Unique).Count
    $r | Add-Member CreationTraces @($split.Creation | ForEach-Object { $_.traceID } | Sort-Object -Unique).Count
    $missing = ''
    $queueWait = $null
    $claimToSent = $null
    if ($r.Traces -gt 0) {
        $spans = @(foreach ($t in $split.Invoice) {
            foreach ($s in $t.spans) {
                $tag = @{}; foreach ($x in $s.tags) { $tag[$x.key] = $x.value }
                [pscustomobject]@{ Name = $s.operationName; Service = $t.processes.($s.processID).serviceName; Tags = $tag
                    End = [long]$s.startTime + [long]$s.duration }
            }
        })
        $queue = @($spans | Where-Object { $_.Name -eq 'outbox.queue_wait' })
        if ($queue.Count) { $queueWait = [double]$queue[0].Tags['outbox.queue_wait_seconds'] }
        # Kuyruktan ilk alınma (kuyruk beklemesi adımının bitişi) -> Sent sonuçlu denemenin bitişi; Jaeger'da zamanlar mikrosaniye.
        $sent = @($spans | Where-Object { $_.Name -eq 'outbox.attempt' -and $_.Tags['outbox.outcome'] -eq 'Sent' } | Sort-Object End | Select-Object -First 1)
        if ($queue.Count -and $sent.Count) { $claimToSent = ($sent[0].End - ($queue | Measure-Object End -Minimum).Minimum) / 60e6 }
        $attempts = @($spans | Where-Object { $_.Name -eq 'outbox.attempt' } | ForEach-Object { [int]$_.Tags['outbox.attempt'] } | Sort-Object -Unique)
        $hooks = @($spans | Where-Object { $_.Service -eq 'invoice-service' -and $_.Name -like 'POST /api/v1/erp-webhooks*' }).Count
        $gaps = @()
        if ($queue.Count -lt 1) { $gaps += 'kuyruk beklemesi' }
        $absent = @(1..[math]::Max(1, $r.Attempts) | Where-Object { $attempts -notcontains $_ })
        if ($r.Attempts -gt 0 -and $absent.Count -gt 0) { $gaps += "deneme $($absent -join ',')" }
        if ($hooks -lt $r.Events) { $gaps += "haber $hooks/$($r.Events)" }
        $missing = $gaps -join '; '
    }
    $r | Add-Member Missing $missing
    $r | Add-Member QueueWaitMinutes $(if ($null -ne $queueWait) { $queueWait / 60 } else { $null })
    $r | Add-Member ClaimToSentMinutes $claimToSent
}

$sorunsuz = @($rows | Where-Object { $_.Status -ne 'Başarısız' -and $_.Attempts -lt 3 })
$sorunlu = @($rows | Where-Object { $_.Status -eq 'Başarısız' -or $_.Attempts -ge 3 })
function Format-Ratio($All) {
    $all = @($All); $kept = @($all | Where-Object { $_.Traces -gt 0 }).Count
    if ($all.Count) { '{0} / {1} ({2:P1})' -f $kept, $all.Count, ($kept / $all.Count) } else { '- (fatura yok)' }
}

Write-Title 'Sayım'
Write-Line "Koşu: $RunId; $($rows.Count) fatura; Jaeger'da arama aralığı $($from.ToString('HH:mm:ss'))-$($to.ToString('HH:mm:ss')) UTC."
Write-Line "İzi saklanan = fatura izi (kuyruktan ilk alınışta başlayan iz) bulunan fatura; oluşturma izi ayrı sayılır."
Write-Line ''
$testStart = ($rows | Measure-Object -Property Created -Minimum).Minimum
foreach ($r in $rows) { $r | Add-Member SentMinute $(if ($r.Processed) { ($r.Processed - $testStart).TotalMinutes } else { $null }) }
Write-Line "Saklanan sorunsuz fatura oranı (izi saklanan / fatura), gönderimin bittiği ana göre (test başlangıcı $($testStart.ToString('HH:mm:ss')) UTC):"
Write-Line ("  Hepsi: {0}" -f (Format-Ratio $sorunsuz))
Write-Line '  Testin 10 dakikalık dilimleri:'
$sorunsuz | Where-Object { $null -ne $_.SentMinute } | Group-Object { [int][math]::Floor($_.SentMinute / 10) } |
    Sort-Object { [int]$_.Name } | ForEach-Object {
        $b = [int]$_.Name
        Write-Line ("    {0,3}-{1,3} dk: {2}" -f ($b * 10), ($b * 10 + 10), (Format-Ratio $_.Group))
    }
$noProcessed = @($sorunsuz | Where-Object { $null -eq $_.SentMinute }).Count
if ($noProcessed) { Write-Line "  Gönderimi bitmemiş sorunsuz fatura: $noProcessed" }
Write-Line ''
$lost = @($sorunlu | Where-Object { $_.Traces -eq 0 })
$partial = @($sorunlu | Where-Object { $_.Traces -gt 0 -and $_.Missing })
$failed = @($rows | Where-Object { $_.Status -eq 'Başarısız' }).Count
Write-Line "Sorunlu faturalar (en az 3 deneme ya da Başarısız): $($sorunlu.Count)"
Write-Line ("  En az 3 kez denenen: {0}; Başarısız: {1}" -f @($rows | Where-Object { $_.Attempts -ge 3 }).Count, $failed)
Write-Line "  İzi saklanan: $($sorunlu.Count - $lost.Count); izi kaybolan: $($lost.Count); izi eksik adımlı: $($partial.Count)"
foreach ($x in @($lost + $partial) | Select-Object -First 20) {
    Write-Line "    $($x.Number) deneme=$($x.Attempts) durum=$($x.Status) iz=$($x.Traces): $(if ($x.Missing) { $x.Missing } else { 'iz yok' })"
}
$multi = @($rows | Where-Object { $_.Traces -gt 1 }).Count
$partialAll = @($rows | Where-Object { $_.Traces -gt 0 -and $_.Missing }).Count
Write-Line "Birden fazla fatura izi olan fatura: $multi; eksik adımlı saklanan fatura izi (bütün faturalar): $partialAll"
Write-Line ''
$noCreation = @($rows | Where-Object { $_.CreationTraces -eq 0 })
$multiCreation = @($rows | Where-Object { $_.CreationTraces -gt 1 }).Count
Write-Line ("Oluşturma isteği fatura numarasıyla bulunan fatura: {0} / {1}; bulunmayan: {2}; birden fazla oluşturma izi: {3}" -f ($rows.Count - $noCreation.Count), $rows.Count, $noCreation.Count, $multiCreation)
foreach ($x in $noCreation | Select-Object -First 20) { Write-Line "    $($x.Number): oluşturma izi yok" }
Write-Line ''
Write-Line "Kuyruktan ilk alınmadan gönderilmeye (Sent sonuçlu denemenin bitişi) geçen süre, izi saklanan faturalar; karar süresi $([math]::Round($DecisionWaitSeconds / 60, 2)) dk:"
foreach ($g in @(@('Sorunsuz', $sorunsuz), @('Sorunlu', $sorunlu))) {
    $d = @(@($g[1]) | Where-Object { $null -ne $_.ClaimToSentMinutes } | ForEach-Object { $_.ClaimToSentMinutes } | Sort-Object)
    if (-not $d.Count) { Write-Line "  $($g[0]): ölçülen yok"; continue }
    $q = { param($x) $d[[math]::Min($d.Count - 1, [int][math]::Floor($x * $d.Count))] }
    Write-Line ('  {0}: {1} fatura; p50 {2:N2}, p90 {3:N2}, p99 {4:N2}, en uzun {5:N2} dk; karar süresinden uzun: {6}' -f $g[0], $d.Count,
        (& $q 0.5), (& $q 0.9), (& $q 0.99), $d[-1], @($d | Where-Object { $_ -gt $DecisionWaitSeconds / 60 }).Count)
}
$waits = @($rows | Where-Object { $null -ne $_.QueueWaitMinutes } | ForEach-Object { $_.QueueWaitMinutes } | Sort-Object)
if ($waits.Count) {
    $p = { param($q) $waits[[math]::Min($waits.Count - 1, [int][math]::Floor($q * $waits.Count))] }
    Write-Line ('Kuyruk beklemesi (izi saklanan faturalar, oluşturma -> kuyruktan ilk alınma): p50 {0:N1}, p90 {1:N1}, en uzun {2:N1} dk; 30 dk''dan uzun: {3}' -f (& $p 0.5), (& $p 0.9), $waits[-1], @($waits | Where-Object { $_ -gt 30 }).Count)
}

$report | Set-Content $out -Encoding UTF8
$rows | Select-Object Number, Attempts, Status, Events, @{ n = 'Created'; e = { $_.Created.ToString('o') } },
    @{ n = 'Processed'; e = { if ($_.Processed) { $_.Processed.ToString('o') } } }, @{ n = 'WaitMinutes'; e = { if ($null -ne $_.WaitMinutes) { [math]::Round($_.WaitMinutes, 2) } } },
    @{ n = 'SentMinute'; e = { if ($null -ne $_.SentMinute) { [math]::Round($_.SentMinute, 2) } } },
    @{ n = 'QueueWaitMinutes'; e = { if ($null -ne $_.QueueWaitMinutes) { [math]::Round($_.QueueWaitMinutes, 2) } } },
    @{ n = 'ClaimToSentMinutes'; e = { if ($null -ne $_.ClaimToSentMinutes) { [math]::Round($_.ClaimToSentMinutes, 2) } } }, Traces, CreationTraces, Missing |
    Export-Csv (Join-Path $OutputDir "$prefix-faturalar.csv") -NoTypeInformation -Encoding UTF8
Write-Host "  Çıktı: manual-tests\output\$prefix-sayim.txt (+ -faturalar.csv)" -ForegroundColor DarkGray

Write-Result ($lost.Count -eq 0 -and $partial.Count -eq 0 -and $noCreation.Count -eq 0) `
    "sorunlu faturaların (en az 3 deneme ya da Başarısız; bu koşuda Başarısız $failed) hepsinin fatura izi saklandı ve tam; her faturanın oluşturma isteği numarasıyla bulunuyor"
