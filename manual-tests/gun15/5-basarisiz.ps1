# Örnekleme kuralı: kalıcı olarak Başarısız olan faturaların izlerinin hepsi saklanır (yeni iz yapısıyla). Varsayılan
# simülatör oranlarında Başarısız fatura oluşmadığı için ayrı, kısa bir koşu: simülatör yalnız 500 döndürür, faturalar
# 10 denemeden sonra Başarısız olur; Collector'ın kararından sonra her faturanın fatura izi ve oluşturma izi sayılır
# (2-sayim.ps1).
#   .\manual-tests\gun15\5-basarisiz.ps1
#   .\manual-tests\gun15\5-basarisiz.ps1 -Count 30 -Name basarisiz-2
# Koşu kendi boş volume'leriyle (staj-tasks_*-db-data-gun15-<Name>) açılır; Collector ve Jaeger yeniden başlatılır. Simülatör
# deneme bitince (hata olsa da) varsayılan ayarlarına döner.
param([int]$Count = 30, [string]$Name = 'basarisiz')

. "$PSScriptRoot\_common.ps1"

Write-Title "Başarısız faturaların izleri ($Count fatura, simülatör yalnız ServerError)"
Use-Gun10Volumes "gun15-$Name"
Clear-SimulatorEnv
Invoke-Compose @('up', '-d', '--build', '--force-recreate', 'invoice-db', 'erp-db', 'invoice-service', 'erp-simulator')
Wait-Health $ServiceUrl
Wait-Health $SimulatorUrl
$existing = [int]@(Get-ServiceRows 'SELECT count(*) FROM invoices;')[0]
if ($existing -ne 0) { throw "gun15-$Name volume'ü boş değil ($existing fatura); docker volume rm ile silip yeniden çalıştırın ya da -Name verin." }
Invoke-Compose @('up', '-d', '--force-recreate', 'otel-collector', 'jaeger')
Start-Sleep -Seconds 5

$runId = "GUN15-$Name-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
try {
    Restart-Simulator @{ Simulator__Rates__Success = 0; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 100
        Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0 }
    $result = Invoke-LoadTest @{ BASE_URLS = 'http://invoice-service:8080'; RATE = 5; DURATION = "$([math]::Ceiling($Count / 5))s"; RUN_ID = $runId }
    Write-Step 'Faturaların Başarısız olması bekleniyor (10 deneme, en çok 60 sn bekleme)'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $queued = [int]@(Get-ServiceRows "SELECT count(*) FROM erp_outbox o JOIN invoices i ON i.invoice_number = o.invoice_number WHERE i.customer_code = '$runId' AND o.status = 'Bekliyor';")[0]
        if ($queued -eq 0) { break }
        if ($watch.Elapsed.TotalMinutes -gt 20) { throw "20 dakikada bitmedi ($queued kayıt bekliyor)." }
        Start-Sleep -Seconds 15
    }
    $settled = [DateTimeOffset]::UtcNow
    Write-Host ("  {0}: kuyrukta bekleyen kayıt yok" -f (Format-Duration $watch.Elapsed.TotalSeconds))
}
finally { Restart-Simulator }

$statuses = @(Get-ServiceRows "SELECT status, count(*) FROM invoices WHERE customer_code = '$runId' GROUP BY status;")
Write-Host "  Faturalar: $($statuses -join '; ')"
$wait = $DecisionWaitSeconds + 60
Write-Step "Collector'ın kararları için $wait sn bekleniyor"
Start-Sleep -Seconds $wait

& "$PSScriptRoot\2-sayim.ps1" -RunId $runId -Name $Name
$failed = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE customer_code = '$runId' AND status = 'Başarısız';")[0]
Write-Result ($failed -eq $Count -and $result.accepted -eq $Count) `
    "$Count faturanın $failed'i Başarısız oldu; izlerinin sayımı yukarıda (2-sayim.ps1)"
