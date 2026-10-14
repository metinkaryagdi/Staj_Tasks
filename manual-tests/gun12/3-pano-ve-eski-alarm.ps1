# Kontrol listesi 1: beta paket kaldırıldıktan sonra pano çalışıyor ve önceki beş alarmdan biri (ErpyeUlasilamiyor)
# yeniden tetiklenip çözülüyor. Ekran görüntüleri (pano, alıcının logu) script çalışırken tarayıcıdan alınır.
#   .\manual-tests\gun12\3-pano-ve-eski-alarm.ps1
# Koşul Gün 11'deki gibi: ERP Simülatörü durdurulur ve 30 fatura oluşturulur, her deneme "ulaşılamadı" ile biter.
# Çözülme: simülatör başlatılır; faturalar gönderilir, 5 dakikalık pencerede başarılı gönderimler çoğunluğa geçer.
# Simülatör yaklaşık 1,5 dakikadan uzun kapalı kalırsa MetrikToplanamiyor (erp-simulator) da tetiklenir; beklenen.
param([int]$Count = 30)

. "$PSScriptRoot\_common.ps1"

Write-Title 'Kontrol listesi 1: pano ve önceki bir alarm'

Show-AlertRule 'ErpyeUlasilamiyor'
$since = Get-UtcStamp

Write-Step 'ERP Simülatörü durduruluyor'
Invoke-Compose @('stop', 'erp-simulator')
Write-Step "$Count fatura oluşturuluyor"
$numbers = @(1..$Count | ForEach-Object { (New-ServiceInvoice).InvoiceNumber })

$passed = Test-AlertCycle 'ErpyeUlasilamiyor' $since -FireTimeoutSeconds 180 -ResolveTimeoutSeconds 600 -Resolve {
    Restart-Simulator
    Wait-InvoicesIn $numbers @('Gönderildi', 'İşleme Alındı', 'Onaylandı', 'Reddedildi', 'Başarısız') 300 'sonuçlandı' | Out-Null
}
Show-ServiceQuery "SELECT status, count(*) FROM invoices WHERE invoice_number IN ($(InList $numbers)) GROUP BY status;"

# Pano faturalar gönderildikten ve bir mutabakat çalıştıktan sonra kontrol edilir: gönderim süresi ve mutabakat süresi
# histogramları servis yeniden başladıktan sonraki ilk ölçüme kadar yoktur. Son mutabakatın zamanı veritabanından 15 sn'de
# bir okunur, 5 sn'de bir gönderilir ve toplanır.
Write-Step 'Bir mutabakat çalıştırılıyor (panonun mutabakat panelleri için)'
Show-Run (Invoke-Reconciliation).run.id
Start-Sleep -Seconds 25
Write-Step 'Panonun sorguları'
$panels = @(Test-DashboardQueries)
$panels | ForEach-Object { Write-Host ("  [{0}] {1}: {2} seri" -f $(if ($_.Tamam) { 'OK' } else { 'BOŞ' }), $_.Panel, $_.Seri) }
$panelsOk = @($panels | Where-Object { -not $_.Tamam }).Count -eq 0
Write-Result $panelsOk 'Panonun bütün sorguları değer döndürüyor'

$lines = @(Get-ReceiverLines $since)
$lines | Set-Content (Join-Path $OutputDir 'gun12-3-alarm-alici.txt') -Encoding UTF8
Write-Step 'Alıcının logundaki alarm satırları (bu koşu)'
$lines | ForEach-Object { Write-Host ('  ' + ($_ -replace ' summary=.*$', '')) }
Write-Result ($panelsOk -and $passed) 'Pano çalışıyor; ErpyeUlasilamiyor tetiklendi ve çözüldü bildirimi geldi (alıcının logu)'
Write-Host '  Alıcının satırları: manual-tests\output\gun12-3-alarm-alici.txt' -ForegroundColor DarkGray
