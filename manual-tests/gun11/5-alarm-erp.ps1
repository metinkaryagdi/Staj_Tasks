# Alarm 3 (ErpyeUlasilamiyor): son 5 dakikadaki gönderimlerin yarısından fazlası zaman aşımı ya da ulaşılamadı.
#   .\manual-tests\gun11\5-alarm-erp.ps1
# Koşul: ERP Simülatörü durdurulur (docker compose stop) ve 30 fatura oluşturulur; her deneme "ulaşılamadı" ile biter.
# Çözülme: simülatör başlatılır; faturalar gönderilir, 5 dakikalık pencerede başarılı gönderimler çoğunluğa geçer.
#   .\manual-tests\gun11\5-alarm-erp.ps1 -Timeout
# Zaman aşımı yolu: simülatör durdurulmaz, her isteğe geç cevap verir (LateResponse %100, 30 sn); her POST servisin 10 sn'lik
# zaman aşımına takılır ve "zaman aşımı" ile biter.
param([int]$Count = 30, [switch]$Timeout)

. "$PSScriptRoot\_common.ps1"

Write-Title 'Alarm 3: ERP''ye ulaşılamıyor'
Show-AlertRule 'ErpyeUlasilamiyor'
$since = Get-UtcStamp

if ($Timeout) {
    Restart-Simulator @{
        Simulator__Rates__Success = 0; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0
        Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 100
    }
}
else {
    Write-Step 'ERP Simülatörü durduruluyor'
    Invoke-Compose @('stop', 'erp-simulator')
}
Write-Step "$Count fatura oluşturuluyor"
$numbers = @(1..$Count | ForEach-Object { (New-ServiceInvoice).InvoiceNumber })

$passed = Test-AlertCycle 'ErpyeUlasilamiyor' $since -FireTimeoutSeconds 180 -ResolveTimeoutSeconds 600 -Resolve {
    Restart-Simulator
    Wait-InvoicesIn $numbers @('Gönderildi', 'İşleme Alındı', 'Onaylandı', 'Reddedildi', 'Başarısız') 300 'sonuçlandı' | Out-Null
}
Show-ServiceQuery "SELECT status, count(*) FROM invoices WHERE invoice_number IN ($(InList $numbers)) GROUP BY status;"
Write-Result $passed 'Alarm tetiklendi ve çözüldü bildirimi geldi (alıcının logu)'
