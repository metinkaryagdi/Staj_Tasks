# Gün 3 - Madde 1: hata oranları 0 iken 100 fatura.
# Beklenen: hepsi Gönderildi, simülatörde her faturadan tam bir kayıt, erp_reference değerleri iki tarafta birebir aynı.
. "$PSScriptRoot\_common.ps1"

Write-Title '1) Hata oranları 0 -> 100 fatura: hepsi Gönderildi, simülatörde her biri tek kayıt, referanslar aynı'

Wait-Service
Restart-Simulator @{ Simulator__Rates__Success = 100; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0
                     Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0 }

Write-Step '100 fatura oluşturuluyor, kuyruk boşalana kadar bekleniyor (GET /api/v1/invoices?status=Bekliyor)'
$range = New-ServiceInvoices 100
$seconds = Wait-QueueDrained $range.From $range.To 120
Write-Host "  Kuyruk $seconds sn'de boşaldı."

Write-Step 'Karşılaştırma: servisteki her fatura simülatörün GET endpoint''iyle sorgulanıyor'
$c = Compare-Invoices -From $range.From -To $range.To

$dbOk = Test-DbAllSent -Title 'Madde 1: hata oranları 0' -From $range.From -To $range.To -Count 100

$passed = $c.SentFound -eq 100 -and $c.MultipleRecords -eq 0 -and $c.ReferenceMatches -eq 100 -and $c.Unknown -eq 0 -and $dbOk
Restart-Simulator
Write-Result $passed "100 fatura: $($c.SentFound) Gönderildi ve simülatörde var, birden fazla kaydı olan $($c.MultipleRecords), referansı aynı $($c.ReferenceMatches)/100"
