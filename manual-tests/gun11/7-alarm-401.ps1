# Alarm 5 (CokSayida401): son 5 dakikada 20'den fazla haber 401 aldı.
#   .\manual-tests\gun11\7-alarm-401.ps1
# Koşul: yanlış imzalı 21 haber gönderilir (Fatura Servisi 401 döner). Önce 20 haber gönderilip alarmın tetiklenmediği
# görülür (eşik "20'den fazla"). Çözülme: haberlerin üzerinden 5 dakika geçince kendiliğinden.
# Kural, sayaçların 5 dakika önceki değerini kullanır: Fatura Servisi en az 5 dakikadır açık olmalıdır. Simülatör sahte ve
# tekrar oynatılan haber göndermeden başlatılır; script son 5 dakikada hiç 401 olmayana kadar bekler, sonunda simülatörü
# varsayılan ayarlarla yeniden başlatır.
. "$PSScriptRoot\_common.ps1"

function Send-BadEvents([int]$Count) {
    $codes = 1..$Count | ForEach-Object {
        $body = [Text.Encoding]::UTF8.GetBytes((New-WebhookBody "gun11-401-$_-$(Get-Random)" 'invoice.received' 'FTR-000001' 'ERP-1' $null))
        (Send-Webhook $body (Get-UnixNow) ('0' * 64)).Status
    }
    ($codes | Group-Object | ForEach-Object { "$($_.Name) x $($_.Count)" }) -join ', '
}

Write-Title 'Alarm 5: 5 dakikada 20''den fazla 401'
Show-AlertRule 'CokSayida401'

# The simulator's fake and replayed events also get 401; they would be counted with the test's 20.
Restart-Simulator @{ Webhooks__Problems__FakeRate = 0; Webhooks__Problems__ReplayRate = 0 }
Write-Step 'Fatura Servisi en az 5 dakikadır açık ve son 5 dakikada 401 yok mu'
$last5m = 'sum(erp_webhooks_received_total{result="401"}) - sum(erp_webhooks_received_total{result="401"} offset 5m)'
while ((Get-PrometheusValue $last5m) -ne 0) {
    Write-Host "  $(Get-Date -Format 'HH:mm:ss') son 5 dakikadaki 401: $(Get-PrometheusValue $last5m), bekleniyor" -ForegroundColor DarkGray
    Start-Sleep -Seconds 30
}
$since = Get-UtcStamp

Write-Step 'Yanlış imzalı 20 haber'
Write-Host "  $(Send-BadEvents 20)"
Start-Sleep -Seconds 45
$early = @(Get-ReceiverLines $since | Where-Object { $_ -match 'alertname=CokSayida401 ' })
$state = (Get-ActiveAlerts | Where-Object { $_.Alarm -eq 'CokSayida401' }).Durum
Write-Host ("  45 sn sonra: Prometheus'ta 5 dakikadaki 401 = {0}, alarm {1}, alıcıda satır {2}" -f
    (Get-PrometheusValue $last5m),
    $(if ($state) { $state } else { 'yok' }), $early.Count)
$notAt20 = -not $state -and $early.Count -eq 0

Write-Step 'Yanlış imzalı 1 haber daha (toplam 21)'
Write-Host "  $(Send-BadEvents 1)"
$passed = Test-AlertCycle 'CokSayida401' $since -FireTimeoutSeconds 120 -ResolveTimeoutSeconds 420 -Resolve {
    Write-Host '  Koşul için bir şey yapılmaz: haberler 5 dakikalık pencereden çıkınca kalkar.' -ForegroundColor DarkGray
}
Restart-Simulator
Write-Result ($passed -and $notAt20) '20 haberde tetiklenmedi, 21. haberde tetiklendi ve 5 dakika sonra çözüldü bildirimi geldi'
