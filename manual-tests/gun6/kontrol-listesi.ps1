# Gün 6 - kontrol listesinin script'le çalışan maddelerini (1-5 ve 8) sırayla çalıştırır, sonunda sonuçları tablo halinde yazar.
# 6, 7, 9 ve 10. maddeler ekranda elle yapılır (gun6\README.md); 1 ve 2. maddelerin sonucu ayrıca ekranda da kontrol edilir.
# Toplam ~15 dk. Script'ler simülatörü ve Fatura Servisi'ni yeniden başlatır; bu sırada başka bir test çalıştırmayın.
# Ekrandaki bütün çıktı ayrıca manual-tests\output\gun6-kontrol-listesi-<zaman>.log dosyasına yazılır.
#   .\manual-tests\gun6\kontrol-listesi.ps1            -> hepsi
#   .\manual-tests\gun6\kontrol-listesi.ps1 -From 3    -> 3'ten başlayarak
param([int]$From = 1)

$scripts = @(
    @{ No = 1; File = '..\gun5\ek-eski-takili-fatura.ps1'; Name = '25 saat eski, kararı gelmemiş fatura düzeltiliyor' }
    @{ No = 2; File = '..\gun5\ek-duzeltme-hatasi.ps1';    Name = 'Düzeltmesi hata veren fatura bulgu olarak kaydediliyor' }
    @{ No = 3; File = '3-ozet-1000.ps1';                   Name = '1000 fatura: Özet sayıları = veritabanı' }
    @{ No = 4; File = '4-liste-1000.ps1';                  Name = 'Liste: durum filtresi, arama, sayfalama' }
    @{ No = 5; File = '5-detay.ps1';                       Name = 'Detay: outbox, haberler, bulgular = veritabanı' }
    @{ No = 8; File = '8-toplu-yeniden-gonder.ps1';        Name = '20 Başarısız fatura toplu yeniden gönderiliyor' }
) | Where-Object { $_.No -ge $From }

$outputDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'output'
New-Item -ItemType Directory -Force $outputDir | Out-Null
$log = Join-Path $outputDir ("gun6-kontrol-listesi-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$results = @()
$total = [Diagnostics.Stopwatch]::StartNew()
Start-Transcript -Path $log | Out-Null
try {
    foreach ($s in $scripts) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $result = 'SONUÇ YOK'
        $global:Gun3LastResult = $null
        try {
            & (Join-Path $PSScriptRoot $s.File)
            if ($global:Gun3LastResult -eq $true) { $result = 'GEÇTİ' }
            elseif ($global:Gun3LastResult -eq $false) { $result = 'KALDI' }
        }
        catch {
            $result = "HATA: $($_.Exception.Message)"
            Write-Host $result -ForegroundColor Red
        }
        $results += [pscustomobject]@{ No = $s.No; Test = $s.Name; Script = (Split-Path $s.File -Leaf); Sonuc = $result; Sure = [math]::Round($watch.Elapsed.TotalMinutes, 1) }
    }
}
finally {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host ' GÜN 6 KONTROL LİSTESİ - ÖZET (1-5 ve 8; 6, 7, 9, 10 ekrandan elle: gun6\README.md)' -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor Cyan
    foreach ($r in $results) {
        $color = if ($r.Sonuc -eq 'GEÇTİ') { 'Green' } else { 'Red' }
        Write-Host ('  {0}  {1,-52} {2,-30} {3,5} dk  {4}' -f $r.No, $r.Test, $r.Script, $r.Sure, $r.Sonuc) -ForegroundColor $color
    }
    Write-Host ''
    Write-Host ("  Toplam süre: {0:N1} dk. Bütün çıktı: {1}" -f $total.Elapsed.TotalMinutes, $log) -ForegroundColor DarkGray
    Stop-Transcript | Out-Null
}
if (@($results | Where-Object { $_.Sonuc -ne 'GEÇTİ' }).Count -gt 0 -or $results.Count -ne $scripts.Count) { exit 1 }
