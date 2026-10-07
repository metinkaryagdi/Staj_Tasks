# Gün 7 - bütün script'leri tek seferde çalıştırır: kontrol listesinin script'le çalışan maddeleri (1, 3, 5, 6, 7, 8) ve
# ekler; sonunda sonuçları tablo halinde yazar. 2 ve 4. maddeler ekranda elle yapılır (gun7\README.md).
# Script'ler simülatörü ve Fatura Servisi'ni yeniden başlatır; bu sırada başka bir test çalıştırmayın.
# Sıra, bir script'in ihtiyaç duyduğu veriyi öncekinin bırakacağı şekilde, boş bir veritabanında da çalışması için belirlenmiştir:
# 7. madde (adim4) 5-6. maddeden (adim2) önce çalışır, çünkü adim2 hazır Başarısız fatura ister ve uygulama kendiliğinden
# neredeyse hiç Başarısız fatura üretmez; adim4'ün eklediği ERP'nin hiç almadığı faturalar bu ihtiyacı karşılar.
# Ekrandaki bütün çıktı ayrıca manual-tests\output\gun7-kontrol-listesi-<zaman>.log dosyasına yazılır.
#   .\manual-tests\gun7\kontrol-listesi.ps1            -> hepsi
#   .\manual-tests\gun7\kontrol-listesi.ps1 -From 5    -> 5. adımdan (Adım sütunu) başlayarak
param([int]$From = 1)

$scripts = @(
    @{ No = '1';   Order = 1; File = 'adim1-takili.ps1';            Name = 'Takılı süzgeci = özetteki sayı = veritabanı' }
    @{ No = '3';   Order = 2; File = 'adim3-karar-yok.ps1';         Name = 'ERP Karar Vermedi; karar gelince düzeltme' }
    @{ No = '7';   Order = 3; File = 'adim4-gereksiz-sorgu.ps1';    Name = '50 eski Başarısız: 50 sorgu, sonra 0' }
    @{ No = '5-6'; Order = 4; File = 'adim2-operator.ps1';          Name = 'operator_actions doğru ad ve sonuç; başlıksız 400' }
    @{ No = '8';   Order = 5; File = 'adim5-calisma-sayfalari.ps1'; Name = '120 çalışma sayfa sayfa' }
    @{ No = 'Ek';  Order = 6; File = 'ek-24-saat-siniri.ps1';       Name = '"Kayıt yok" 24 saat dolunca yeniden soruluyor' }
    @{ No = 'Ek';  Order = 7; File = 'ek-sorgu-ayari.ps1';          Name = 'NotFoundRecheckHours ayardan okunuyor' }
    @{ No = 'Ek';  Order = 8; File = 'ek-zamanlayici.ps1';          Name = 'Zamanlanmış çalışmanın başlatanı' }
    @{ No = 'Ek';  Order = 9; File = 'ek-elle-takip.ps1';           Name = 'Takılı faturayı elle takibe alma' }
) | Where-Object { $_.Order -ge $From }

$outputDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'output'
New-Item -ItemType Directory -Force $outputDir | Out-Null
$log = Join-Path $outputDir ("gun7-kontrol-listesi-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
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
        $results += [pscustomobject]@{ Order = $s.Order; No = $s.No; Test = $s.Name; Script = $s.File; Sonuc = $result; Sure = [math]::Round($watch.Elapsed.TotalMinutes, 1) }
    }
}
finally {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host ' GÜN 7 KONTROL LİSTESİ - ÖZET (2 ve 4 ekrandan elle: gun7\README.md)' -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host ('  {0,-5} {1,-5} {2,-50} {3,-28} {4,8}  {5}' -f 'Adım', 'Madde', 'Test', 'Script', 'Süre', 'Sonuç')
    foreach ($r in $results) {
        $color = if ($r.Sonuc -eq 'GEÇTİ') { 'Green' } else { 'Red' }
        Write-Host ('  {0,-5} {1,-5} {2,-50} {3,-28} {4,5} dk  {5}' -f $r.Order, $r.No, $r.Test, $r.Script, $r.Sure, $r.Sonuc) -ForegroundColor $color
    }
    Write-Host ''
    Write-Host ("  Toplam süre: {0:N1} dk. Bütün çıktı: {1}" -f $total.Elapsed.TotalMinutes, $log) -ForegroundColor DarkGray
    Stop-Transcript | Out-Null
}
if (@($results | Where-Object { $_.Sonuc -ne 'GEÇTİ' }).Count -gt 0 -or $results.Count -ne $scripts.Count) { exit 1 }
