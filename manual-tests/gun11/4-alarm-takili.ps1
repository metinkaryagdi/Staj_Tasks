# Alarm 2 (TakiliFaturaCok): takılı fatura sayısı 10 dakika boyunca 50'nin üzerinde.
#   .\manual-tests\gun11\4-alarm-takili.ps1
# Koşul: simülatör her faturayı kabul eder ama karar haberini hiç göndermez (LostDecisionRate 100); 60 fatura İşleme
# Alındı'da kalır ve 2 dakika sonra takılı sayılır. Fatura Servisi baştan başlatılır ki zamanlanmış mutabakat (60 dakikada
# bir) test sırasında çalışıp faturaları düzeltmesin. Çözülme: mutabakat elle çalıştırılır, ERP'nin kararıyla faturalar
# düzelir, takılı sayısı düşer.
param([int]$Count = 60)

. "$PSScriptRoot\_common.ps1"

Write-Title 'Alarm 2: 50''den fazla takılı fatura'
Show-AlertRule 'TakiliFaturaCok'
$since = Get-UtcStamp

Restart-InvoiceService
Restart-Simulator @{
    Simulator__Rates__Success = 100; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0
    Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0
    Webhooks__Problems__LostDecisionRate = 100
}
Write-Step "$Count fatura oluşturuluyor"
$numbers = @(1..$Count | ForEach-Object { (New-ServiceInvoice).InvoiceNumber })
Wait-InvoicesIn $numbers @('Gönderildi', 'İşleme Alındı') 120 'gönderildi' | Out-Null
Write-Host "  $Count fatura gönderildi; karar haberi gelmeyecek."

$passed = Test-AlertCycle 'TakiliFaturaCok' $since -FireTimeoutSeconds 1080 -ResolveTimeoutSeconds 300 -Resolve {
    Restart-Simulator
    Show-Run (Invoke-Reconciliation).run.id
    Write-Host ("  Takılı fatura (veritabanı): {0}" -f [int]@(Get-ServiceRows (Get-StuckSql 2 'count(*)'))[0]) -ForegroundColor DarkGray
}
Write-Result $passed 'Alarm tetiklendi ve çözüldü bildirimi geldi (alıcının logu)'
