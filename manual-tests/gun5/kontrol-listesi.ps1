# Gün 5 - kontrol listesinin 2-9. maddelerini sırayla çalıştırır, sonunda her birinin sonucunu tablo halinde yazar.
# 1. madde (Gün 3 ve Gün 4 listelerinin aynı sonucu vermesi) kendi script'leriyle çalıştırılır:
#   .\manual-tests\gun3\kontrol-listesi.ps1   ve   .\manual-tests\gun4\kontrol-listesi.ps1
# Toplam ~20 dk. Script'ler simülatörü ve Fatura Servisi'ni yeniden başlatır, 8. madde ikinci bir servis kopyası açıp kapatır,
# 9. madde simülatörü dondurur (docker pause): bu sırada başka bir test çalıştırmayın.
# Ekrandaki bütün çıktı ayrıca manual-tests\output\gun5-kontrol-listesi-<zaman>.log dosyasına yazılır.
#   .\manual-tests\gun5\kontrol-listesi.ps1            -> hepsi
#   .\manual-tests\gun5\kontrol-listesi.ps1 -From 4    -> 4'ten başlayarak
param([int]$From = 2)

$scripts = @(
    @{ No = 2; File = '2-500-fatura.ps1';             Name = 'Varsayılan oranlar, 500 fatura, mutabakat' }
    @{ No = 3; File = '3-erpde-var-serviste-yok.ps1'; Name = 'ERP''de olup serviste olmayan fatura' }
    @{ No = 4; File = '4-tutar-farki.ps1';            Name = 'Simülatörde elle değişen tutar' }
    @{ No = 5; File = '5-cift-kayit.ps1';             Name = 'İkinci gönderim: ERP''de çift kayıt' }
    @{ No = 6; File = '6-basarisiz-geri-getir.ps1';   Name = 'Elle Başarısız yapılan fatura geri geliyor' }
    @{ No = 7; File = '7-taninmayan-haber.ps1';       Name = 'Tanınmayan faturanın haberi Yok Sayıldı' }
    @{ No = 8; File = '8-iki-kopya.ps1';              Name = 'İki kopya + elle başlatma: tek çalışma, 409' }
    @{ No = 9; File = '9-simulator-durdu.ps1';        Name = 'Simülatör ulaşılamaz: Başarısız, fatura değişmez' }
) | Where-Object { $_.No -ge $From }

$outputDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'output'
New-Item -ItemType Directory -Force $outputDir | Out-Null
$log = Join-Path $outputDir ("gun5-kontrol-listesi-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
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
    Write-Host ' GÜN 5 KONTROL LİSTESİ - ÖZET (2-9; 1. madde Gün 3 ve Gün 4 listeleridir)' -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor Cyan
    foreach ($r in $results) {
        $color = if ($r.Sonuc -eq 'GEÇTİ') { 'Green' } else { 'Red' }
        Write-Host ('  {0}  {1,-46} {2,-30} {3,5} dk  {4}' -f $r.No, $r.Test, $r.Script, $r.Sure, $r.Sonuc) -ForegroundColor $color
    }
    Write-Host ''
    Write-Host ("  Toplam süre: {0:N1} dk. Bütün çıktı: {1}" -f $total.Elapsed.TotalMinutes, $log) -ForegroundColor DarkGray
    Stop-Transcript | Out-Null
}
if (@($results | Where-Object { $_.Sonuc -ne 'GEÇTİ' }).Count -gt 0 -or $results.Count -ne $scripts.Count) { exit 1 }
