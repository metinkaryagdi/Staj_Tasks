# Test 6: Varsayılan oranlarla aynı seed kullanarak 50 faturayı iki kez gönder.
# Beklenen: iki çalıştırmada loglardaki davranış dizisi birebir aynı.
# Ayarlar appsettings.json'dan gelir (seed 42). Her çalıştırmadan önce simülatör yeniden başlatılır,
# böylece seed'li dizi en baştan başlar. Geç cevaplar yüzünden toplam birkaç dakika sürebilir.
param([int]$Count = 50)
. "$PSScriptRoot\_common.ps1"

Write-Title "6) Varsayılan oranlar, aynı seed, $Count fatura x 2 çalıştırma: davranış dizisi birebir aynı"

New-Item -ItemType Directory -Force $OutputDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$sequences = @{}

foreach ($run in 'A', 'B') {
    Write-Title "Çalıştırma $run"
    Restart-Simulator

    $prefix = "T6-$stamp-$run-"
    Write-Step "$Count fatura gönderiliyor (fatura no: $prefix<1..$Count>)"
    foreach ($i in 1..$Count) { Write-Response (Send-Invoice "$prefix$i") }

    # Davranışlar cevaptan değil, simülatörün kendi logundan okunur.
    $logLines = @(Get-SimulatorLog | Where-Object { $_ -match "invoice=$([regex]::Escape($prefix))\d+ behavior=" })
    $logFile = Join-Path $OutputDir "6-seed-$stamp-$run.log"
    $logLines | Set-Content -Encoding UTF8 $logFile

    $sequences[$run] = @($logLines | ForEach-Object { if ($_ -match 'behavior=(\w+)') { $Matches[1] } })
    Write-Host "  Log satırları kaydedildi: $logFile" -ForegroundColor DarkGray
}

Write-Title 'Karşılaştırma (loglardan)'
$a = $sequences['A']; $b = $sequences['B']
$max = [math]::Max($a.Count, $b.Count)
$different = 0
Write-Host ('  {0,4}  {1,-15} {2,-15}' -f '#', 'Çalıştırma A', 'Çalıştırma B')
for ($i = 0; $i -lt $max; $i++) {
    $same = $a[$i] -eq $b[$i]
    if (-not $same) { $different++ }
    Write-Host ('  {0,4}  {1,-15} {2,-15} {3}' -f ($i + 1), $a[$i], $b[$i], $(if ($same) { '' } else { '<-- FARKLI' })) `
        -ForegroundColor $(if ($same) { 'Gray' } else { 'Red' })
}

$summary = ($a | Group-Object | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
Write-Host ''
Write-Host "  Dağılım: $summary"

Write-Result ($a.Count -eq $Count -and $b.Count -eq $Count -and $different -eq 0) `
    "A: $($a.Count) davranış, B: $($b.Count) davranış, farklı sıra: $different"
