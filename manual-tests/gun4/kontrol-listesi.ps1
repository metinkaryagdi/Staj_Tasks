# Gün 4 - kontrol listesinin 8 maddesini sırayla çalıştırır, sonunda her birinin sonucunu tablo halinde yazar. ~15-20 dk.
# Script'ler simülatörü yeniden başlatır, 5. madde Fatura Servisi'ni 2 dk durdurur: bu sırada başka bir test çalıştırmayın.
# Ekrandaki bütün çıktı ayrıca manual-tests\output\gun4-kontrol-listesi-<zaman>.log dosyasına yazılır.
#   .\manual-tests\gun4\kontrol-listesi.ps1            -> hepsi
#   .\manual-tests\gun4\kontrol-listesi.ps1 -From 4    -> 4'ten başlayarak
param([int]$From = 1)

$scripts = @(
    @{ No = 1; File = 'adim0-ondalik.ps1';     Name = 'Üç ondalıklı tutar iki tarafta 400' }
    @{ No = 2; File = '2-sorunsuz-100.ps1';    Name = 'Oranlar 0, 100 fatura' }
    @{ No = 3; File = '3-varsayilan-500.ps1';  Name = 'Varsayılan oranlar, 500 fatura' }
    @{ No = 4; File = '4-sira-karismasi.ps1';  Name = 'Sıra karışması %100, 20 fatura' }
    @{ No = 5; File = '5-servis-kapali.ps1';   Name = 'Servis 2 dk kapalı' }
    @{ No = 6; File = '6-gec-cevap.ps1';       Name = 'Geç cevap %100, 10 fatura' }
    @{ No = 7; File = 'adim2-imza.ps1';        Name = 'Üç geçersiz istek 401, yazılmıyor' }
    @{ No = 8; File = '8-paralel.ps1';         Name = 'Aynı haber 10 kez paralel' }
) | Where-Object { $_.No -ge $From }

$outputDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'output'
New-Item -ItemType Directory -Force $outputDir | Out-Null
$log = Join-Path $outputDir ("gun4-kontrol-listesi-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
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
        $results += [pscustomobject]@{ No = $s.No; Test = $s.Name; Script = $s.File; Sonuc = $result; Sure = [math]::Round($watch.Elapsed.TotalMinutes, 1) }
    }
}
finally {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host ' GÜN 4 KONTROL LİSTESİ - ÖZET' -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor Cyan
    foreach ($r in $results) {
        $color = if ($r.Sonuc -eq 'GEÇTİ') { 'Green' } else { 'Red' }
        Write-Host ('  {0}  {1,-36} {2,-22} {3,5} dk  {4}' -f $r.No, $r.Test, $r.Script, $r.Sure, $r.Sonuc) -ForegroundColor $color
    }
    Write-Host ''
    Write-Host ("  Toplam süre: {0:N1} dk. Bütün çıktı: {1}" -f $total.Elapsed.TotalMinutes, $log) -ForegroundColor DarkGray
    Stop-Transcript | Out-Null
}
if (@($results | Where-Object { $_.Sonuc -ne 'GEÇTİ' }).Count -gt 0 -or $results.Count -ne $scripts.Count) { exit 1 }
