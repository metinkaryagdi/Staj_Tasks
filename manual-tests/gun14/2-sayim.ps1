# Kontrol listesi 2'nin sayımı: uzun yük testinin faturalarından hangilerinin izi Jaeger'da saklandı.
#   .\manual-tests\gun14\2-sayim.ps1 -RunId GUN14-uzun-20261016-090000
# 1-uzun-yuk.ps1 koşunun sonunda bunu çağırır; ayrıca çalıştırılırsa aynı koşu yeniden sayılır (yığın o koşunun
# volume'leriyle açık ve Collector/Jaeger o koşudan beri yeniden başlamamış olmalı).
#
# Gruplar Fatura Servisi veritabanından (customer_code = koşu kimliği):
#   Sorunsuz: Başarısız değil ve 3'ten az denendi. Sorunlu: en az 3 kez denendi ya da Başarısız.
# Sorunsuzlar testin zamanına göre ikiye ayrılır: gönderimi (erp_outbox.processed_at) testin ilk 30 dakikasında bitenler
# ve 30 dakikadan sonra bitenler. Testin başlangıcı koşunun ilk faturasının oluşturulduğu andır.
# Saklanan iz Jaeger'dan: invoice.number etiketi faturanın numarası olan trace. Saklanan izin tam olup olmadığı da
# bakılır: oluşturma isteği, 1..send_attempt_count numaralı bütün denemeler ve veritabanındaki her ERP haberi.
# Çıktı output\gun14-2-<Name>-sayim.txt ve -faturalar.csv (fatura başına sonuç).
param([Parameter(Mandatory)][string]$RunId, [string]$Name = 'uzun')

. "$PSScriptRoot\_common.ps1"
Use-Gun10Volumes "gun14-$Name"

$prefix = "gun14-2-$Name"
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
Write-Step "Jaeger'da her faturanın izi aranıyor"
$from = ($rows | Measure-Object -Property Created -Minimum).Minimum.AddMinutes(-1)
$to = [DateTimeOffset]::UtcNow
$watch = [Diagnostics.Stopwatch]::StartNew()
$i = 0
foreach ($r in $rows) {
    $i++
    if ($i % 1000 -eq 0) { Write-Host ("  {0} / {1} ({2})" -f $i, $rows.Count, (Format-Duration $watch.Elapsed.TotalSeconds)) -ForegroundColor DarkGray }
    $tags = [Uri]::EscapeDataString((@{ 'invoice.number' = $r.Number } | ConvertTo-Json -Compress))
    $traces = @((Get-JaegerJson "$JaegerUrl/api/traces?service=invoice-service&tags=$tags&start=$(ConvertTo-JaegerTime $from)&end=$(ConvertTo-JaegerTime $to)&limit=100").data)
    $r | Add-Member Traces @($traces | ForEach-Object { $_.traceID } | Sort-Object -Unique).Count
    $missing = ''
    if ($r.Traces -gt 0) {
        $spans = @(foreach ($t in $traces) {
            foreach ($s in $t.spans) {
                $tag = @{}; foreach ($x in $s.tags) { $tag[$x.key] = $x.value }
                [pscustomobject]@{ Name = $s.operationName; Service = $t.processes.($s.processID).serviceName; Tags = $tag }
            }
        })
        $post = @($spans | Where-Object { $_.Service -eq 'invoice-service' -and $_.Name -like 'POST /api/v1/invoices*' }).Count
        $attempts = @($spans | Where-Object { $_.Name -eq 'outbox.attempt' } | ForEach-Object { [int]$_.Tags['outbox.attempt'] } | Sort-Object -Unique)
        $hooks = @($spans | Where-Object { $_.Service -eq 'invoice-service' -and $_.Name -like 'POST /api/v1/erp-webhooks*' }).Count
        $gaps = @()
        if ($post -lt 1) { $gaps += 'oluşturma' }
        $absent = @(1..[math]::Max(1, $r.Attempts) | Where-Object { $attempts -notcontains $_ })
        if ($r.Attempts -gt 0 -and $absent.Count -gt 0) { $gaps += "deneme $($absent -join ',')" }
        if ($hooks -lt $r.Events) { $gaps += "haber $hooks/$($r.Events)" }
        $missing = $gaps -join '; '
    }
    $r | Add-Member Missing $missing
}

$sorunsuz = @($rows | Where-Object { $_.Status -ne 'Başarısız' -and $_.Attempts -lt 3 })
$sorunlu = @($rows | Where-Object { $_.Status -eq 'Başarısız' -or $_.Attempts -ge 3 })
function Format-Ratio($All) {
    $all = @($All); $kept = @($all | Where-Object { $_.Traces -gt 0 }).Count
    if ($all.Count) { '{0} / {1} ({2:P1})' -f $kept, $all.Count, ($kept / $all.Count) } else { '- (fatura yok)' }
}

Write-Title 'Sayım'
Write-Line "Koşu: $RunId; $($rows.Count) fatura; Jaeger'da arama aralığı $($from.ToString('HH:mm:ss'))-$($to.ToString('HH:mm:ss')) UTC."
Write-Line ''
$testStart = ($rows | Measure-Object -Property Created -Minimum).Minimum
foreach ($r in $rows) { $r | Add-Member SentMinute $(if ($r.Processed) { ($r.Processed - $testStart).TotalMinutes } else { $null }) }
Write-Line "Saklanan sorunsuz fatura oranı (izi saklanan / fatura), gönderimin bittiği ana göre (test başlangıcı $($testStart.ToString('HH:mm:ss')) UTC):"
Write-Line ("  İlk 30 dakika:      {0}" -f (Format-Ratio @($sorunsuz | Where-Object { $null -ne $_.SentMinute -and $_.SentMinute -le 30 })))
Write-Line ("  30 dakikadan sonra: {0}" -f (Format-Ratio @($sorunsuz | Where-Object { $_.SentMinute -gt 30 })))
Write-Line ("  Hepsi:              {0}" -f (Format-Ratio $sorunsuz))
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
Write-Line "Sorunlu faturalar (en az 3 deneme ya da Başarısız): $($sorunlu.Count)"
Write-Line ("  En az 3 kez denenen: {0}; Başarısız: {1}" -f @($rows | Where-Object { $_.Attempts -ge 3 }).Count, @($rows | Where-Object { $_.Status -eq 'Başarısız' }).Count)
Write-Line "  İzi saklanan: $($sorunlu.Count - $lost.Count); izi kaybolan: $($lost.Count); izi eksik adımlı: $($partial.Count)"
foreach ($x in @($lost + $partial) | Select-Object -First 20) {
    Write-Line "    $($x.Number) deneme=$($x.Attempts) durum=$($x.Status) iz=$($x.Traces): $(if ($x.Missing) { $x.Missing } else { 'iz yok' })"
}
$multi = @($rows | Where-Object { $_.Traces -gt 1 }).Count
$partialAll = @($rows | Where-Object { $_.Traces -gt 0 -and $_.Missing }).Count
Write-Line "Birden fazla trace'i olan fatura: $multi; eksik adımlı saklanan iz (bütün faturalar): $partialAll"
$waits = @($rows | Where-Object { $null -ne $_.WaitMinutes } | ForEach-Object { $_.WaitMinutes } | Sort-Object)
if ($waits.Count) {
    $p = { param($q) $waits[[math]::Min($waits.Count - 1, [int][math]::Floor($q * $waits.Count))] }
    Write-Line ('Kuyruk beklemesi (bütün faturalar, oluşturma -> gönderimin bitmesi): p50 {0:N1}, p90 {1:N1}, en uzun {2:N1} dk' -f (& $p 0.5), (& $p 0.9), $waits[-1])
}

$report | Set-Content $out -Encoding UTF8
$rows | Select-Object Number, Attempts, Status, Events, @{ n = 'Created'; e = { $_.Created.ToString('o') } },
    @{ n = 'Processed'; e = { if ($_.Processed) { $_.Processed.ToString('o') } } }, @{ n = 'WaitMinutes'; e = { if ($null -ne $_.WaitMinutes) { [math]::Round($_.WaitMinutes, 2) } } }, @{ n = 'SentMinute'; e = { if ($null -ne $_.SentMinute) { [math]::Round($_.SentMinute, 2) } } }, Traces, Missing |
    Export-Csv (Join-Path $OutputDir "$prefix-faturalar.csv") -NoTypeInformation -Encoding UTF8
Write-Host "  Çıktı: manual-tests\output\$prefix-sayim.txt (+ -faturalar.csv)" -ForegroundColor DarkGray

Write-Result ($lost.Count -eq 0 -and $partial.Count -eq 0 -and @($rows | Where-Object { $_.Status -eq 'Başarısız' }).Count -gt 0) `
    'sorunlu faturaların (en az 3 deneme ya da Başarısız) hepsinin izi saklandı ve tam; koşuda Başarısız fatura var'
