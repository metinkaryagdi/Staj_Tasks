# Gün 7 - kontrol listesinin script'le çalışan maddelerini (1, 3, 5, 6, 7, 8) sırayla çalıştırır, sonunda sonuçları tablo
# halinde yazar. 2 ve 4. maddeler ekranda elle yapılır (gun7\README.md). Toplam ~12 dk. Script'ler simülatörü ve Fatura
# Servisi'ni yeniden başlatır; bu sırada başka bir test çalıştırmayın.
# Ekrandaki bütün çıktı ayrıca manual-tests\output\gun7-kontrol-listesi-<zaman>.log dosyasına yazılır.
#   .\manual-tests\gun7\kontrol-listesi.ps1            -> hepsi
#   .\manual-tests\gun7\kontrol-listesi.ps1 -From 5    -> 5'ten başlayarak
param([int]$From = 1)

$scripts = @(
    @{ No = '1';   Order = 1; File = 'adim1-takili.ps1';            Name = 'Takılı süzgeci = özetteki sayı = veritabanı' }
    @{ No = '3';   Order = 3; File = 'adim3-karar-yok.ps1';         Name = 'ERP Karar Vermedi; karar gelince düzeltme' }
    @{ No = '5-6'; Order = 5; File = 'adim2-operator.ps1';          Name = 'operator_actions doğru ad ve sonuç; başlıksız 400' }
    @{ No = '7';   Order = 7; File = 'adim4-gereksiz-sorgu.ps1';    Name = '50 eski Başarısız: 50 sorgu, sonra 0' }
    @{ No = '8';   Order = 8; File = 'adim5-calisma-sayfalari.ps1'; Name = '120 çalışma sayfa sayfa' }
    @{ No = 'Ek';  Order = 9; File = 'ek-zamanlayici.ps1';          Name = 'Zamanlanmış çalışmanın başlatanı' }
    @{ No = 'Ek';  Order = 10; File = 'ek-elle-takip.ps1';          Name = 'Takılı faturayı elle takibe alma' }
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
        $results += [pscustomobject]@{ No = $s.No; Test = $s.Name; Script = $s.File; Sonuc = $result; Sure = [math]::Round($watch.Elapsed.TotalMinutes, 1) }
    }
}
finally {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host ' GÜN 7 KONTROL LİSTESİ - ÖZET (2 ve 4 ekrandan elle: gun7\README.md)' -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor Cyan
    foreach ($r in $results) {
        $color = if ($r.Sonuc -eq 'GEÇTİ') { 'Green' } else { 'Red' }
        Write-Host ('  {0,-4} {1,-50} {2,-28} {3,5} dk  {4}' -f $r.No, $r.Test, $r.Script, $r.Sure, $r.Sonuc) -ForegroundColor $color
    }
    Write-Host ''
    Write-Host ("  Toplam süre: {0:N1} dk. Bütün çıktı: {1}" -f $total.Elapsed.TotalMinutes, $log) -ForegroundColor DarkGray
    Stop-Transcript | Out-Null
}
if (@($results | Where-Object { $_.Sonuc -ne 'GEÇTİ' }).Count -gt 0 -or $results.Count -ne $scripts.Count) { exit 1 }
