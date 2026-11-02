# O3'ün derecesi için: Jaeger'a kimliksiz istekle hangi fatura verisi okunuyor. 20 fatura oluşturur, izlerin örnekleme
# kararını (decision_wait 2 dk) bekler, sonra Jaeger'ın API'sinden token'sız okur ve izlerdeki fatura alanlarını sayar.
# Çıktı manual-tests\output\gun21\<-Etiket>.txt. ~3 dk.
#   .\manual-tests\gun21\0-jaeger-fatura-verisi.ps1
param([string]$Etiket = 'a0-jaeger-fatura-verisi')
. "$PSScriptRoot\_common.ps1"

New-Report $Etiket
Write-Title 'Jaeger: kimliksiz istekle okunan fatura verisi'
Start-Stack
Write-Line "Koşu: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

$order = Get-OrderSystemToken
$numbers = foreach ($i in 1..20) {
    (Send-Api POST '/api/v1/invoices' $order '{"customerCode":"GUN21-JAEGER","amount":10.5,"currency":"TRY","invoiceDate":"2026-11-02"}').Json.invoiceNumber
}
Write-Line "Oluşturulan faturalar: $($numbers[0]) … $($numbers[-1])"
Write-Line 'Örnekleme kararı için 150 sn bekleniyor'
Start-Sleep -Seconds 150

$traces = Send-Http GET 'http://localhost:16686/api/traces?service=invoice-service&lookback=1h&limit=200'
Write-Line "GET http://localhost:16686/api/traces?service=invoice-service (Authorization yok): HTTP $($traces.Status)"
$data = ($traces.Body | ConvertFrom-Json).data
$tags = @($data | ForEach-Object { $_.spans } | ForEach-Object { $_.tags })
Write-Line "İz sayısı: $($data.Count), span sayısı: $(@($data | ForEach-Object { $_.spans }).Count)"
foreach ($key in 'invoice.number', 'invoice.status', 'erp.reference', 'erp_event.status') {
    $values = @($tags | Where-Object { $_.key -eq $key -and $_.value } | ForEach-Object { "$($_.value)" } | Sort-Object -Unique)
    Write-Line ("{0,-18} {1,4} farklı değer; örnek: {2}" -f $key, $values.Count, (($values | Select-Object -First 3) -join ', '))
}
Save-Report
