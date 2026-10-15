# Kontrol listesi 2: sistem 5 dakika boşta kaldığında Jaeger'a worker sorgusu izi düşmüyor.
#   .\manual-tests\gun13\2-bosta.ps1
# Yığın çalışırken ve iş yokken (kuyrukta bekleyen kayıt, simülatörde gönderilmeyi bekleyen haber yok) 5 dakikalık bir
# pencere açılır. Bu sürede worker'lar sorgularını yapmaya devam eder (kuyruk 250 ms'de bir, veritabanı metrikleri 15 sn'de
# bir, simülatörün worker'ları). Pencere bittikten sonra Collector'ın karar süresi (decision_wait) ve gönderim payı kadar
# beklenir: ondan önce Jaeger'da iz olmaması, kararın henüz verilmemiş olmasından da olabilir. Sonra Jaeger'da iki servis
# için pencerede başlayan bütün trace'ler sayılır; kök span'e göre ayrılır (outbox.claim, yalnız veritabanı span'i, diğer).
param([int]$IdleMinutes = 5)

. "$PSScriptRoot\_common.ps1"

Write-Title "Kontrol listesi 2: $IdleMinutes dakika boşta, worker sorgusu izi yok"
Wait-Health $ServiceUrl
Wait-Health $SimulatorUrl

$queued = [int]@(Get-ServiceRows "SELECT count(*) FROM erp_outbox WHERE status = 'Bekliyor';")[0]
$pending = [int]@(Get-ErpRows "SELECT count(*) FROM webhook_deliveries WHERE status IN ('Pending', 'Waiting');")[0]
Write-Host "  Kuyrukta bekleyen kayıt: $queued, simülatörde gönderilmeyi bekleyen haber: $pending"
if ($queued -ne 0 -or $pending -ne 0) { throw 'Sistem boşta değil; iş bitince yeniden çalıştırın.' }

$from = [DateTimeOffset]::UtcNow
Write-Step "Boşta pencere: $($from.ToString('HH:mm:ss')) UTC'den $IdleMinutes dk"
Start-Sleep -Seconds ($IdleMinutes * 60)
$to = [DateTimeOffset]::UtcNow
$wait = $DecisionWaitSeconds + 60
Write-Step "Pencere bitti ($($to.ToString('HH:mm:ss')) UTC); Collector'ın kararları için $wait sn bekleniyor"
Start-Sleep -Seconds $wait

# Pencerede yeni iş başlamadığını da göster: oluşturulan fatura ve gelen haber yok.
$invoices = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE created_at >= '$($from.ToString('o'))' AND created_at < '$($to.ToString('o'))';")[0]
$events = [int]@(Get-ServiceRows "SELECT count(*) FROM erp_webhook_events WHERE received_at >= '$($from.ToString('o'))' AND received_at < '$($to.ToString('o'))';")[0]

$lines = [Collections.Generic.List[string]]::new()
$lines.Add("Boşta pencere: $($from.ToString('yyyy-MM-dd HH:mm:ss'))-$($to.ToString('HH:mm:ss')) UTC; sayım $wait sn sonra.")
$lines.Add("Pencerede oluşturulan fatura: $invoices, gelen ERP haberi: $events.")
$total = 0; $claim = 0; $dbOnly = 0
foreach ($service in @((Get-JaegerJson "$JaegerUrl/api/services").data | Where-Object { $_ -ne 'jaeger' })) {
    $traces = @(Get-ServiceTraces $service $from $to)
    foreach ($t in $traces) {
        $root = @($t.spans | Where-Object { -not ($_.references | Where-Object refType -eq 'CHILD_OF') } | Select-Object -First 1)
        $dbOnly += [int](@($t.spans | Where-Object { -not ($_.tags | Where-Object key -eq 'db.system.name') -and -not ($_.tags | Where-Object key -eq 'db.system') }).Count -eq 0)
        $claim += [int]($root.operationName -eq 'outbox.claim')
        $lines.Add("  $service trace $($t.traceID): kök $($root.operationName), $($t.spans.Count) span")
    }
    $total += $traces.Count
    $lines.Add("Jaeger, $service : pencerede başlayan trace $($traces.Count)")
}
$lines.Add("Toplam: $total; kökü outbox.claim olan: $claim; yalnız veritabanı span'inden oluşan: $dbOnly.")
$lines | ForEach-Object { Write-Host "  $_" }
$lines | Set-Content (Join-Path $OutputDir 'gun13-2-bosta.txt') -Encoding UTF8

Write-Result ($total -eq 0 -and $invoices -eq 0 -and $events -eq 0) `
    "$IdleMinutes dk boşta: Jaeger'da pencerede başlayan trace yok (worker sorgusu izi 0)"
