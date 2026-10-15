# Kontrol listesi 1'in sayımı: bir yük testi koşusunun faturalarından hangilerinin izi Jaeger'da saklandı.
#   .\manual-tests\gun13\1-sayim.ps1 -RunId GUN13-yuk-20261015-124438
# 1-yuk-ornekleme.ps1 koşunun sonunda bunu çağırır; ayrıca çalıştırılırsa aynı koşu yeniden sayılır (yığın o koşunun
# volume'leriyle açık ve Collector/Jaeger o koşudan beri yeniden başlamamış olmalı).
#
# Gruplar Fatura Servisi veritabanından (customer_code = koşu kimliği):
#   Sorunsuz: Başarısız değil ve 3'ten az denendi. En az 3 deneme: send_attempt_count >= 3. Başarısız: durum Başarısız.
# Saklanan iz Jaeger'dan: invoice.number etiketi faturanın numarası olan trace (servis invoice-service). Saklanan izin tam
# olup olmadığı da bakılır: oluşturma isteği, 1..send_attempt_count numaralı bütün denemeler ve veritabanındaki her ERP
# haberi için servisin haber span'i.
# Çıktı output\gun13-1-<Name>-sayim.txt ve output\gun13-1-<Name>-faturalar.csv (fatura başına sonuç).
param([Parameter(Mandatory)][string]$RunId, [string]$Name = 'yuk')

. "$PSScriptRoot\_common.ps1"
Use-Gun10Volumes "gun13-$Name"

$out = Join-Path $OutputDir "gun13-1-$Name-sayim.txt"
$report = [Collections.Generic.List[string]]::new()
function Write-Line([string]$Text) { Write-Host $Text; $report.Add($Text) }

Write-Step 'Faturalar veritabanından okunuyor'
# Zamanlar epoch saniyesi (ondalıklı): psql'e giden sorguda tırnak ve biçim karakterleri kullanılmaz.
$rows = @(Get-ServiceRows @"
SELECT i.invoice_number, i.send_attempt_count, i.status,
       (SELECT count(*) FROM erp_webhook_events e WHERE e.invoice_number = i.invoice_number),
       extract(epoch FROM i.created_at)::numeric(16,3), extract(epoch FROM i.updated_at)::numeric(16,3)
FROM invoices i WHERE i.customer_code = '$RunId' ORDER BY i.invoice_number;
"@ | ForEach-Object {
    $c = $_.Split('|')
    $inv = [Globalization.CultureInfo]::InvariantCulture
    [pscustomobject]@{ Number = $c[0]; Attempts = [int]$c[1]; Status = $c[2]; Events = [int]$c[3]
        Created = [DateTimeOffset]::FromUnixTimeMilliseconds([long]([double]::Parse($c[4], $inv) * 1000))
        Updated = [DateTimeOffset]::FromUnixTimeMilliseconds([long]([double]::Parse($c[5], $inv) * 1000)) }
})
if ($rows.Count -eq 0) { throw "$RunId koşusunun faturası yok." }
Write-Host "  $($rows.Count) fatura"

Write-Step "Jaeger'da her faturanın izi aranıyor"
$from = ($rows | Measure-Object -Property Created -Minimum).Minimum.AddMinutes(-1)
$to = [DateTimeOffset]::UtcNow
$i = 0
foreach ($r in $rows) {
    $i++
    if ($i % 500 -eq 0) { Write-Host "  $i / $($rows.Count)" -ForegroundColor DarkGray }
    $ids = @(Get-InvoiceTraceIds $r.Number $from $to)
    $r | Add-Member Traces $ids.Count
    $missing = ''
    if ($ids.Count -gt 0) {
        $spans = @($ids | ForEach-Object { Get-TraceSpans $_ })
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

$groups = [ordered]@{
    'Sorunsuz faturalar' = @($rows | Where-Object { $_.Status -ne 'Başarısız' -and $_.Attempts -lt 3 })
    'En az 3 kez denenen faturalar' = @($rows | Where-Object { $_.Attempts -ge 3 })
    'Kalıcı olarak Başarısız olan faturalar' = @($rows | Where-Object { $_.Status -eq 'Başarısız' })
}

Write-Title 'Sayım'
Write-Line "Koşu: $RunId; $($rows.Count) fatura; Jaeger'da arama aralığı $($from.ToString('HH:mm:ss'))-$($to.ToString('HH:mm:ss')) UTC."
Write-Line ''
Write-Line ('{0,-42} {1,13} {2,13} {3,8} {4,22}' -f 'Fatura grubu', 'Fatura sayısı', 'İzi saklanan', 'Oran', 'Saklanan ama eksik adım')
foreach ($g in $groups.Keys) {
    $all = $groups[$g]
    $kept = @($all | Where-Object { $_.Traces -gt 0 })
    $partial = @($kept | Where-Object { $_.Missing })
    $ratio = if ($all.Count) { '{0:P1}' -f ($kept.Count / $all.Count) } else { '-' }
    Write-Line ('{0,-42} {1,13} {2,13} {3,8} {4,22}' -f $g, $all.Count, $kept.Count, $ratio, $partial.Count)
}
$overlap = @($groups['Kalıcı olarak Başarısız olan faturalar'] | Where-Object { $_.Attempts -ge 3 }).Count
Write-Line "Not: Başarısız faturaların $overlap tanesi en az 3 kez denendi; iki satırda da sayılır."
Write-Line ''
Write-Line 'Sorunsuz faturalar deneme sayısına göre:'
foreach ($n in 1, 2) {
    $all = @($groups['Sorunsuz faturalar'] | Where-Object { $_.Attempts -eq $n })
    $kept = @($all | Where-Object { $_.Traces -gt 0 })
    $ratio = if ($all.Count) { '{0:P1}' -f ($kept.Count / $all.Count) } else { '-' }
    Write-Line ("  {0} deneme: {1} fatura, izi saklanan {2} ({3})" -f $n, $all.Count, $kept.Count, $ratio)
}
$multi = @($rows | Where-Object { $_.Traces -gt 1 })
Write-Line "Birden fazla trace'i olan fatura: $($multi.Count)"
$partialAll = @($rows | Where-Object { $_.Missing })
if ($partialAll.Count) {
    Write-Line 'Eksik adımlı saklanan faturalar (ilk 20):'
    $partialAll | Select-Object -First 20 | ForEach-Object { Write-Line "  $($_.Number) deneme=$($_.Attempts) durum=$($_.Status): $($_.Missing)" }
}

$report | Set-Content $out -Encoding UTF8
$rows | Select-Object Number, Attempts, Status, Events, @{ n = 'Created'; e = { $_.Created.ToString('o') } }, @{ n = 'Updated'; e = { $_.Updated.ToString('o') } }, Traces, Missing |
    Export-Csv (Join-Path $OutputDir "gun13-1-$Name-faturalar.csv") -NoTypeInformation -Encoding UTF8
Write-Host "  Çıktı: manual-tests\output\gun13-1-$Name-sayim.txt (+ -faturalar.csv)" -ForegroundColor DarkGray

$sorunsuz = $groups['Sorunsuz faturalar']
$ratioOk = $sorunsuz.Count -gt 0 -and [math]::Abs(@($sorunsuz | Where-Object { $_.Traces -gt 0 }).Count / $sorunsuz.Count - 0.10) -le 0.03
$allKept = @($groups['En az 3 kez denenen faturalar'] + $groups['Kalıcı olarak Başarısız olan faturalar'] | Where-Object { $_.Traces -eq 0 }).Count -eq 0
$hasFailed = $groups['Kalıcı olarak Başarısız olan faturalar'].Count -gt 0
Write-Result ($ratioOk -and $allKept -and $hasFailed -and $partialAll.Count -eq 0) `
    'sorunsuzların ~%10''u (±3 puan), en az 3 denenen ve Başarısız faturaların hepsi saklandı; saklanan her iz tam'
