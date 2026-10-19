# Kontrol listesi 3: kuyrukta 30 dakikadan uzun beklemiş bir faturanın Jaeger ekran görüntüsü. Kuyruk beklemesi
# geriye tarihli adımla görünüyor, oluşturma isteği de fatura numarasıyla bulunabiliyor.
#   .\manual-tests\gun15\3-ekran.ps1
#   .\manual-tests\gun15\3-ekran.ps1 -InvoiceNumber FTR-012345
# 2-sayim.ps1'in çıktısından (output\gun15-2-<Name>-faturalar.csv) kuyrukta 30 dakikadan uzun beklemiş, en az 3 denemeli
# (sorunlu: fatura izi her zaman saklanır), bir fatura izi ve bir oluşturma izi olan bir fatura seçilir. Yığın o koşunun
# volume'leriyle açık ve Jaeger o koşudan beri yeniden başlamamış olmalı (bellek sınırı denemesinden önce çalıştırılır).
# İki görüntü: Jaeger'da fatura numarasıyla arama sonucu (iki iz) ve fatura izi (ilk adım kuyruk beklemesi).
param([string]$Name = 'uzun', [string]$InvoiceNumber = '')

. "$PSScriptRoot\_common.ps1"

Write-Title 'Kontrol listesi 3: kuyrukta 30 dakikadan uzun beklemiş bir faturanın izi'
$csv = Join-Path $OutputDir "gun15-2-$Name-faturalar.csv"
if (-not (Test-Path $csv)) { throw "$csv yok; önce 1-uzun-yuk.ps1 -Name $Name çalıştırılmalı." }
$rows = @(Import-Csv $csv -Encoding UTF8)
$candidates = if ($InvoiceNumber) { @($rows | Where-Object Number -eq $InvoiceNumber) } else {
    @($rows | Where-Object { [int]$_.Attempts -ge 3 -and [int]$_.Traces -eq 1 -and [int]$_.CreationTraces -eq 1 -and [int]$_.Events -ge 2 -and
        $_.QueueWaitMinutes -and [double]::Parse($_.QueueWaitMinutes, [Globalization.CultureInfo]::InvariantCulture) -gt 30 } |
        Sort-Object { [double]::Parse($_.QueueWaitMinutes, [Globalization.CultureInfo]::InvariantCulture) })
}
Write-Host "  Aday (en az 3 deneme, kuyrukta 30 dk'dan uzun, bir fatura izi, bir oluşturma izi, iki haber): $($candidates.Count)"
if ($candidates.Count -eq 0) { throw 'Uygun fatura bulunamadı.' }
# 30 dakikayı az geçen ilk aday: görüntüde izin tamamı bir ekrana sığsın diye en uzun beklemiş olan seçilmez.
$pick = $candidates[0]
$created = [DateTimeOffset]::Parse($pick.Created)
Write-Host ("  Seçilen: {0}, {1} deneme, durum {2}, kuyrukta {3} dk" -f $pick.Number, $pick.Attempts, $pick.Status, $pick.QueueWaitMinutes)

$from = $created.AddMinutes(-1)
$to = [DateTimeOffset]::UtcNow
$tags = @{ 'invoice.number' = $pick.Number } | ConvertTo-Json -Compress
$traces = @((Get-JaegerJson "$JaegerUrl/api/traces?service=invoice-service&tags=$([Uri]::EscapeDataString($tags))&start=$(ConvertTo-JaegerTime $from)&end=$(ConvertTo-JaegerTime $to)&limit=20").data)
$split = Split-InvoiceTraces $traces
if ($split.Invoice.Count -ne 1 -or $split.Creation.Count -ne 1) { throw "$($pick.Number): fatura izi $($split.Invoice.Count), oluşturma izi $($split.Creation.Count)." }
$invoiceTrace = ConvertTo-Trace $split.Invoice[0]
$creationTrace = ConvertTo-Trace $split.Creation[0]

Write-Step 'Fatura izi'
Show-Trace $invoiceTrace 'gun15-3-fatura-izi.txt'
Write-Step 'Oluşturma izi'
Show-Trace $creationTrace 'gun15-3-olusturma-izi.txt'

$root = @($invoiceTrace.Spans | Where-Object { -not $_.ParentId })
$queue = @($invoiceTrace.Spans | Where-Object Name -eq 'outbox.queue_wait')
$rawQueue = @($split.Invoice[0].spans | Where-Object operationName -eq 'outbox.queue_wait')
$queueStart = if ($rawQueue.Count) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]($rawQueue[0].startTime / 1000)) } else { $null }
$post = @($creationTrace.Spans | Where-Object { $_.Service -eq 'invoice-service' -and $_.Name -like 'POST /api/v1/invoices*' })
$postStart = [DateTimeOffset]::FromUnixTimeMilliseconds([long](($split.Creation[0].spans | Measure-Object startTime -Minimum).Minimum / 1000))
Write-Host ("  Fatura izinin kökü: {0}; kuyruk beklemesi {1:N1} dk, başlangıcı {2} UTC (veritabanında oluşturma {3} UTC)" -f `
    (($root | ForEach-Object Name) -join ','), ($queue[0].Ms / 60000), $queueStart.ToString('HH:mm:ss.fff'), $created.ToString('HH:mm:ss.fff'))
Write-Host ("  Oluşturma izi: {0}, başlangıcı {1} UTC" -f (($post | ForEach-Object Name) -join ','), $postStart.ToString('HH:mm:ss.fff'))

Write-Step 'Ekran görüntüleri (başsız Edge)'
$searchUrl = "$JaegerUrl/search?service=invoice-service&tags=$([Uri]::EscapeDataString($tags))&start=$(ConvertTo-JaegerTime $from)&end=$(ConvertTo-JaegerTime $to)&limit=20&lookback=custom"
$traceUrl = "$JaegerUrl/trace/$($invoiceTrace.TraceId)"
Save-Screenshot $searchUrl (Join-Path $OutputDir 'gun15-k3-arama.png') 1800 1100
Save-Screenshot $traceUrl (Join-Path $OutputDir 'gun15-k3-fatura-izi.png') 1800 2400
Write-Host "  Arama: $searchUrl" -ForegroundColor DarkGray
Write-Host "  Fatura izi: $traceUrl" -ForegroundColor DarkGray
Write-Host '  Çıktı: manual-tests\output\gun15-k3-arama.png, gun15-k3-fatura-izi.png (+ gun15-3-fatura-izi.txt, gun15-3-olusturma-izi.txt)' -ForegroundColor DarkGray

$queueOk = $queue.Count -eq 1 -and ($root | ForEach-Object Name) -contains 'outbox.queue_wait' -and $queue[0].Ms -gt 30 * 60000 -and
    [math]::Abs(($queueStart - $created).TotalSeconds) -lt 1
Write-Result ($queueOk -and $post.Count -ge 1) `
    "$($pick.Number): fatura izinin ilk adımı oluşturulma anından başlayan $([math]::Round($queue[0].Ms / 60000, 1)) dk'lık kuyruk beklemesi; oluşturma isteği numarayla ayrı iz olarak bulunuyor"
