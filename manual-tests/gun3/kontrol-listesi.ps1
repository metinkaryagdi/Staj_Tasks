# Gün 3 - kontrol listesinin 7 maddesini sırayla çalıştırır, sonunda her birinin sonucunu tablo halinde yazar.
# Toplam ~26 dk. Script'ler simülatörü ve Fatura Servisi'ni yeniden başlatır (6. madde servisi docker kill ile öldürür,
# 7. madde ikinci bir servis kopyası açıp kapatır): bu sırada başka bir test çalıştırmayın.
# Ekrandaki bütün çıktı ayrıca manual-tests\output\gun3-kontrol-listesi-<zaman>.log dosyasına yazılır.
#   .\manual-tests\gun3\kontrol-listesi.ps1            -> hepsi
#   .\manual-tests\gun3\kontrol-listesi.ps1 -From 4    -> 4'ten başlayarak
param([int]$From = 1)

$scripts = @(
    @{ No = 1; File = '1-hata-yok.ps1';           Name = 'Hata oranları 0, 100 fatura' }
    @{ No = 2; File = '2-varsayilan-1000.ps1';    Name = 'Varsayılan oranlar, 1000 fatura' }
    @{ No = 3; File = '3-mesgul-retry-after.ps1'; Name = 'Busy, Retry-After (iki biçim)' }
    @{ No = 4; File = '4-sunucu-hatasi.ps1';      Name = 'ServerError, backoff, resend' }
    @{ No = 5; File = '5-simulator-kapali.ps1';   Name = 'Simülatör kapalı, 50 fatura' }
    @{ No = 6; File = '6-servis-kill.ps1';        Name = '3 kez docker kill, 200 fatura' }
    @{ No = 7; File = '7-iki-kopya.ps1';          Name = 'İki kopya, 500 fatura' }
) | Where-Object { $_.No -ge $From }

$outputDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'output'
New-Item -ItemType Directory -Force $outputDir | Out-Null
$log = Join-Path $outputDir ("gun3-kontrol-listesi-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
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
    Write-Host ' GÜN 3 KONTROL LİSTESİ - ÖZET' -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor Cyan
    foreach ($r in $results) {
        $color = if ($r.Sonuc -eq 'GEÇTİ') { 'Green' } else { 'Red' }
        Write-Host ('  {0}  {1,-34} {2,-26} {3,5} dk  {4}' -f $r.No, $r.Test, $r.Script, $r.Sure, $r.Sonuc) -ForegroundColor $color
    }
    Write-Host ''
    Write-Host ("  Toplam süre: {0:N1} dk. Bütün çıktı: {1}" -f $total.Elapsed.TotalMinutes, $log) -ForegroundColor DarkGray
    Stop-Transcript | Out-Null
}
# Biri bile GEÇTİ değilse (KALDI, HATA, SONUÇ YOK) çıkış kodu 1: script'i çağıran bir araç başarısızlığı anlayabilsin.
if (@($results | Where-Object { $_.Sonuc -ne 'GEÇTİ' }).Count -gt 0 -or $results.Count -ne $scripts.Count) { exit 1 }
