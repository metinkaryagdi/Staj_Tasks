# Yük testi sürerken özet API'si 100 kez okunur: "Bekliyor" sayısı ile kuyruktaki fatura sayısı her okumada aynı olmalı.
# Özet bütün sayıları tek snapshot'ta okur; fatura "Bekliyor" olarak girip çıkarken iki sayı aynı anı gösterir.
#
# Önce yük testi başlatılır (ayrı pencerede, iki kopyayla):
#   docker compose --profile iki-kopya up -d --build invoice-service invoice-service-2
#   docker compose run --rm -e BASE_URLS=http://invoice-service:8080,http://invoice-service-2:8080 k6
# Sonra bu script (yük testi sürerken):
#   .\manual-tests\gun9\1-ozet-yuk-altinda.ps1
# $Reads okuma, $IntervalMilliseconds arayla; her okumanın "Bekliyor" sayısı, kuyruktaki sayı ve toplamı yazılır.
# Kuyruk boşken okumalar anlamsız olur (iki sayı da 0); script yük başlamadıysa bunu belirtir.
param([int]$Reads = 100, [int]$IntervalMilliseconds = 1500)

. "$PSScriptRoot\_common.ps1"

Write-Title 'Özet: Bekliyor sayısı ve kuyruktaki fatura sayısı yük altında'

$first = (Get-Api '/api/v1/invoices/summary').Json
if ($first.queuedCount -eq 0) { Write-Host '  Kuyruk boş: yük testi sürmüyor olabilir, okumalar bir şey kanıtlamaz.' -ForegroundColor Yellow }

Write-DbHeader "$Reads okuma, $IntervalMilliseconds ms arayla" 'GET /api/v1/invoices/summary:'
$rows = @(); $different = 0; $zero = 0
for ($i = 1; $i -le $Reads; $i++) {
    $summary = (Get-Api '/api/v1/invoices/summary').Json
    $pending = [int]($summary.counts | Where-Object { $_.status -eq 'Bekliyor' }).count
    $queued = [int]$summary.queuedCount
    if ($pending -ne $queued) { $different++ }
    if ($queued -eq 0) { $zero++ }
    $rows += [pscustomobject]@{ Okuma = $i; Saat = (Get-Date -Format 'HH:mm:ss.fff'); Bekliyor = $pending; Kuyrukta = $queued; Toplam = $summary.total; Sonuç = $(if ($pending -eq $queued) { 'aynı' } else { 'FARKLI' }) }
    if ($i -lt $Reads) { Start-Sleep -Milliseconds $IntervalMilliseconds }
}
$rows | Select-Object -First 5 | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
Write-Host '  ...' -ForegroundColor DarkGray
$rows | Select-Object -Last 3 | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$rows | Format-Table -AutoSize | Out-String -Width 200 | Set-Content (Join-Path $OutputDir 'gun9-ozet-yuk-altinda.txt') -Encoding UTF8

$queuedValues = $rows | ForEach-Object { $_.Kuyrukta }
Write-Host ("  Kuyruktaki sayı: en az {0}, en çok {1}; kuyruk boş okunan: {2}" -f ($queuedValues | Measure-Object -Minimum).Minimum, ($queuedValues | Measure-Object -Maximum).Maximum, $zero) -ForegroundColor DarkGray

$check = Write-DbVerdict "$Reads okumanın hepsinde Bekliyor = kuyruktaki sayı" "$($Reads - $different) / $Reads" ($different -eq 0)
Write-Result $check 'Özetteki Bekliyor sayısı ile kuyruktaki fatura sayısı her okumada aynı'
