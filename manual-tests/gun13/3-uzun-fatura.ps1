# Kontrol listesi 3: en az 3 kez denenen ve 10 dakikadan uzun süren bir faturanın izi; yolculuğun bütün adımları
# bulunabiliyor.
#   .\manual-tests\gun13\3-uzun-fatura.ps1
#   .\manual-tests\gun13\3-uzun-fatura.ps1 -InvoiceNumber FTR-001234
# 1-yuk-ornekleme.ps1'in koşusundan (output\gun13-1-<Name>-faturalar.csv) en az 3 denemeli, oluşturulmasından son durum
# değişikliğine kadar 10 dakikadan uzun süren ve izi saklanan bir fatura seçilir (en uzun süren). İzi ağaç olarak yazılır;
# denemelerin hepsi, oluşturma isteği ve ERP haberleri kontrol edilir. Ekran görüntüsü için Jaeger adresi verilir.
param([string]$Name = 'yuk', [string]$InvoiceNumber = '')

. "$PSScriptRoot\_common.ps1"

Write-Title 'Kontrol listesi 3: en az 3 kez denenen, 10 dakikadan uzun süren faturanın izi'
$csv = Join-Path $OutputDir "gun13-1-$Name-faturalar.csv"
if (-not (Test-Path $csv)) { throw "$csv yok; önce 1-yuk-ornekleme.ps1 -Name $Name çalıştırılmalı." }
$rows = @(Import-Csv $csv -Encoding UTF8 | ForEach-Object {
    $_ | Add-Member Minutes (([DateTimeOffset]::Parse($_.Updated) - [DateTimeOffset]::Parse($_.Created)).TotalMinutes) -PassThru
})
# Veritabanındaki süre (oluşturma → son durum değişikliği) mutabakatın sonradan yaptığı düzeltmeyi de içerebilir; asıl ölçü
# izin süresidir (ilk span'in başından son span'in bitişine). Adaylar en az 3 denemeli, izi saklanmış ve iki ERP haberi
# (alındı, karar) gelmiş faturalardır; geç oluşturulanlar kuyrukta uzun beklediği için sondan başlanır, izi 10 dakikadan
# uzun olan ilk fatura seçilir.
$candidates = @($rows | Where-Object { [int]$_.Attempts -ge 3 -and [int]$_.Traces -eq 1 -and [int]$_.Events -ge 2 -and $_.Minutes -gt 10 } |
    Sort-Object { [DateTimeOffset]::Parse($_.Created) } -Descending)
Write-Host "  Aday (en az 3 deneme, izi saklanmış, iki haber, veritabanında 10 dk'dan uzun): $($candidates.Count)"
if ($InvoiceNumber) { $candidates = @($rows | Where-Object Number -eq $InvoiceNumber) }
$pick = $null
foreach ($c in $candidates | Select-Object -First 50) {
    $t = Get-InvoiceTrace $c.Number ([DateTimeOffset]::Parse($c.Created).AddSeconds(-5))
    $end = ($t.Spans | ForEach-Object { $_.Start + $_.Ms } | Measure-Object -Maximum).Maximum
    if ($end / 60000 -gt 10) { $pick = $c; $trace = $t; break }
}
if (-not $pick) { throw 'İzi 10 dakikadan uzun süren uygun fatura bulunamadı.' }
Write-Host ("  Seçilen: {0}, {1} deneme, durum {2}" -f $pick.Number, $pick.Attempts, $pick.Status)

Show-Trace $trace "gun13-3-uzun-fatura.txt"

$spans = $trace.Spans
$attempts = @($spans | Where-Object Name -eq 'outbox.attempt' | ForEach-Object { [int]$_.Tags['outbox.attempt'] } | Sort-Object -Unique)
$post = @($spans | Where-Object { $_.Service -eq 'invoice-service' -and $_.Name -like 'POST /api/v1/invoices*' }).Count
$hooks = @($spans | Where-Object { $_.Service -eq 'invoice-service' -and $_.Name -like 'POST /api/v1/erp-webhooks*' }).Count
$events = [int]$pick.Events
$lastEnd = ($spans | ForEach-Object { $_.Start + $_.Ms } | Measure-Object -Maximum).Maximum
$traceMinutes = $lastEnd / 60000
Write-Host ("  İzde: oluşturma {0}, denemeler {1} (veritabanında {2}), servisin haber span'i {3} (veritabanında {4} haber), ilk span'den son span'in bitişine {5:N1} dk" -f `
    $post, ($attempts -join ','), $pick.Attempts, $hooks, $events, $traceMinutes)
Write-Host "  Ekran görüntüsü: $JaegerUrl/trace/$($trace.TraceId)" -ForegroundColor DarkGray

$allAttempts = (($attempts -join ',') -eq ((1..[int]$pick.Attempts) -join ','))
Write-Result ($post -ge 1 -and $allAttempts -and $hooks -ge $events -and [int]$pick.Attempts -ge 3 -and $traceMinutes -gt 10) `
    "$($pick.Number): tek trace'te oluşturma, $($pick.Attempts) denemenin hepsi ve $events ERP haberi; iz $([math]::Round($traceMinutes, 1)) dk"
