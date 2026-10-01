# Gün 3 - adım testlerinin hepsini sırayla çalıştırır (adim1 ... adim6), sonunda her birinin sonucunu tablo halinde yazar.
# Toplam ~16 dk. Script'ler simülatörü ve Fatura Servisi'ni yeniden başlatır: bu sırada başka bir test çalıştırmayın.
# Ekrandaki bütün çıktı ayrıca manual-tests\output\gun3-adimlar-<zaman>.log dosyasına yazılır.
#   .\manual-tests\gun3\adimlar.ps1            -> hepsi
#   .\manual-tests\gun3\adimlar.ps1 -From 4    -> 4'ten başlayarak
param([int]$From = 1)

$scripts = @(
    @{ No = 1; File = 'adim1-sema.ps1';         Name = 'Şema' }
    @{ No = 2; File = 'adim2-outbox-yazma.ps1'; Name = 'POST outbox''a yazıyor' }
    @{ No = 3; File = 'adim3-worker.ps1';       Name = 'Worker, aynı anda en fazla 10' }
    @{ No = 4; File = 'adim4-tekrar-deneme.ps1'; Name = 'Tekrar deneme kuralları' }
    @{ No = 5; File = 'adim5-cift-kayit.ps1';   Name = 'Çift kayıt koruması' }
    @{ No = 6; File = 'adim6-endpointler.ps1';  Name = 'resend ve listeleme' }
) | Where-Object { $_.No -ge $From }

$outputDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'output'
New-Item -ItemType Directory -Force $outputDir | Out-Null
$log = Join-Path $outputDir ("gun3-adimlar-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
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
    Write-Host ' GÜN 3 ADIM TESTLERİ - ÖZET' -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor Cyan
    foreach ($r in $results) {
        $color = if ($r.Sonuc -eq 'GEÇTİ') { 'Green' } else { 'Red' }
        Write-Host ('  {0}  {1,-32} {2,-26} {3,5} dk  {4}' -f $r.No, $r.Test, $r.Script, $r.Sure, $r.Sonuc) -ForegroundColor $color
    }
    Write-Host ''
    Write-Host ("  Toplam süre: {0:N1} dk. Bütün çıktı: {1}" -f $total.Elapsed.TotalMinutes, $log) -ForegroundColor DarkGray
    Stop-Transcript | Out-Null
}
# Biri bile GEÇTİ değilse (KALDI, HATA, SONUÇ YOK) çıkış kodu 1: script'i çağıran bir araç başarısızlığı anlayabilsin.
if (@($results | Where-Object { $_.Sonuc -ne 'GEÇTİ' }).Count -gt 0 -or $results.Count -ne $scripts.Count) { exit 1 }
