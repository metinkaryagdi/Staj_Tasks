# Gün 4 ek kontroller: oluşma sırası, teslimi bekleyen eski haber, 4xx / 5xx ayrımı.
. "$PSScriptRoot\_common.ps1"
$ErrorActionPreference = 'Stop'
$allPassed = $true
$listener = 'gun4-ek-http-' + (Get-Date -Format 'yyyyMMddHHmmss')
$override = Join-Path $OutputDir "$listener.yml"
$responder = Join-Path $OutputDir "$listener.sh"
New-Item -ItemType Directory -Force $OutputDir | Out-Null
$log = Join-Path $OutputDir ("gun4-ek-simulator-kararlari-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Start-Transcript -Path $log | Out-Null

function Check([string]$Expected, [string]$Actual, [bool]$Passed) {
    if (-not (Write-DbVerdict $Expected $Actual $Passed)) { $script:allPassed = $false }
}
function Cleanup {
    try {
        try { Invoke-Compose @('start', 'invoice-service') } finally { Restart-Simulator }
    }
    finally {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & docker rm -f $listener 2>$null | Out-Null } finally { $ErrorActionPreference = $previous }
        Remove-Item -LiteralPath $override, $responder -ErrorAction SilentlyContinue
    }
}
trap {
    Write-Host "Hata: $_ - servis ve simülatör varsayılan ayarlara döndürülüyor." -ForegroundColor Red
    try { Cleanup } catch { Write-Host "Temizlik hatası: $_" -ForegroundColor Red }
    Write-Result $false 'Ek kontroller tamamlanamadı'
    Stop-Transcript | Out-Null
    exit 1
}

Write-Title 'Ek simülatör kararları A-D'
Wait-Service
Write-Step 'A) Sıra karışması %100; diğer sorunlar 0; 10 fatura'
Restart-Simulator (Get-SimSettings -Problems @{ OrderMixRate = 100 })
$numbers = New-Invoices 10
$list = InList $numbers
Wait-InvoicesIn $numbers @('Gönderildi', 'İşleme Alındı', 'Onaylandı', 'Reddedildi') 60 | Out-Null
Wait-EventsDone $numbers | Out-Null
$pairs = "FROM webhook_deliveries r JOIN webhook_deliveries d ON d.invoice_id = r.invoice_id AND d.kind = 'Normal' AND d.event_type <> 'invoice.received' JOIN invoices i ON i.id = r.invoice_id WHERE r.invoice_number IN ($list) AND r.kind = 'Normal' AND r.event_type = 'invoice.received'"
Show-ErpQuery "SELECT r.invoice_number, i.received_at AS kayit, r.first_sent_at AS received_gonderim, d.first_sent_at AS karar_gonderim, r.payload::jsonb->>'occurred_at' AS received_olusma, d.payload::jsonb->>'occurred_at' AS karar_olusma $pairs ORDER BY 1;"
# Npgsql zamanı mikrosaniyeye keser; JSON dönüşümünde de yedinci basamağı kes (PostgreSQL yuvarlar).
$ordered = Count-Erp "SELECT count(*) $pairs AND d.first_sent_at < r.first_sent_at AND r.occurred_at >= i.received_at AND r.occurred_at < d.occurred_at AND d.occurred_at = d.due_at AND regexp_replace(r.payload::jsonb->>'occurred_at', '([.][0-9]{6})[0-9]', '\1')::timestamptz = r.occurred_at AND regexp_replace(d.payload::jsonb->>'occurred_at', '([.][0-9]{6})[0-9]', '\1')::timestamptz = d.occurred_at;"
Check 'A: 10 faturada gönderim ters, oluşma gerçek sırada ve gövdeler satırlarla aynı' "$ordered" ($ordered -eq 10)
$timed = Count-Erp "SELECT count(*) $pairs AND extract(epoch FROM d.due_at-i.received_at) BETWEEN 2 AND 10 AND extract(epoch FROM r.due_at-d.due_at) BETWEEN 2 AND 20 AND extract(epoch FROM d.first_sent_at-i.received_at) BETWEEN 2 AND 10 AND extract(epoch FROM r.first_sent_at-d.first_sent_at) BETWEEN 2 AND 20;"
Check 'A: 10 faturada ilk gönderim ve plan 2-10 sn, ikinci 2-20 sn' "$timed" ($timed -eq 10)
Show-ServiceQuery "SELECT invoice_number, event_type, occurred_at, received_at, status, ignore_reason FROM erp_webhook_events WHERE invoice_number IN ($list) ORDER BY invoice_number, received_at;"
$serviceOrder = Count-Service "SELECT count(*) FROM erp_webhook_events r JOIN erp_webhook_events d ON d.invoice_number = r.invoice_number AND d.event_type <> 'invoice.received' WHERE r.invoice_number IN ($list) AND r.event_type = 'invoice.received' AND r.occurred_at < d.occurred_at AND r.received_at > d.received_at;"
$final = Count-Service "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status IN ('Onaylandı', 'Reddedildi');"
$ignored = Count-Service "SELECT count(*) FROM erp_webhook_events WHERE invoice_number IN ($list) AND event_type = 'invoice.received' AND status = 'Yok Sayıldı' AND ignore_reason = 'Geri Götürüyor';"
Check 'A: serviste ters sıra 10, kesin fatura 10, received Yok Sayıldı/Geri Götürüyor 10' "$serviceOrder / $final / $ignored" ($serviceOrder -eq 10 -and $final -eq 10 -and $ignored -eq 10)

Write-Step 'B) Eski haber %100; 5 fatura gönderildikten sonra servis yaklaşık 40 sn kapalı'
Restart-Simulator (Get-SimSettings -Problems @{ ReplayRate = 100 })
$numbers = New-Invoices 5
$list = InList $numbers
Wait-InvoicesIn $numbers @('Gönderildi') 60 | Out-Null
Invoke-Compose @('stop', '-t', '0', 'invoice-service')
for ($i = 0; $i -lt 4; $i++) { Start-Sleep -Seconds 10; Write-Host "  Servis kapalı: $(($i+1)*10) sn" }
Show-ErpQuery "SELECT kind, status, count(*) AS haber, max(attempt_count) AS deneme FROM webhook_deliveries WHERE invoice_number IN ($list) GROUP BY 1,2 ORDER BY 1,2;"
$waiting = Count-Erp "SELECT count(*) FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'Replay' AND status = 'Waiting' AND first_sent_at IS NULL AND attempt_count = 0;"
Check 'B: servis kapalıyken 5 eski haber Waiting ve hiç gönderilmemiş' "$waiting" ($waiting -eq 5)
Invoke-Compose @('start', 'invoice-service')
Wait-Service
Wait-EventsDone $numbers | Out-Null
$replays = "FROM webhook_deliveries r JOIN webhook_deliveries n ON n.event_id = r.event_id AND n.kind = 'Normal' WHERE r.invoice_number IN ($list) AND r.kind = 'Replay'"
Show-ErpQuery "SELECT r.invoice_number, n.event_type AS asil, n.completed_at AS asil_teslim, r.first_sent_at AS eski_gonderim, r.status, r.last_http_status, r.attempt_count $replays ORDER BY 1;"
$after = Count-Erp "SELECT count(*) $replays AND n.status = 'Delivered' AND r.first_sent_at >= n.completed_at + interval '1 second' AND r.status = 'Rejected' AND r.last_http_status = 401 AND r.attempt_count = 1;"
Check 'B: 5 eski haber asıl teslimden en az 1 sn sonra, 401/Rejected, 1 deneme' "$after" ($after -eq 5)
$afterReceived = Count-Erp "SELECT count(*) FROM webhook_deliveries r JOIN webhook_deliveries n ON n.invoice_id = r.invoice_id AND n.kind = 'Normal' AND n.event_type = 'invoice.received' WHERE r.invoice_number IN ($list) AND r.kind = 'Replay' AND r.first_sent_at > n.completed_at;"
Check 'B: 5 eski haber invoice.received tesliminden sonra' "$afterReceived" ($afterReceived -eq 5)
Show-ServiceQuery "SELECT invoice_number, event_type, delivery_count FROM erp_webhook_events WHERE invoice_number IN ($list) ORDER BY 1,2;"
$single = Count-Service "SELECT count(*) FROM erp_webhook_events WHERE invoice_number IN ($list) AND delivery_count = 1;"
$total = Count-Service "SELECT count(*) FROM erp_webhook_events WHERE invoice_number IN ($list);"
Check 'B: serviste 10 asıl haber, hepsinde delivery_count 1' "$total / $single" ($total -eq 10 -and $single -eq 10)
Write-Step 'B: Simülatör logundan bir faturanın bütün satırları'
$sample = $numbers[0]
Get-SimulatorLog | Where-Object { $_ -match "invoice=$sample(?: |$)" } | ForEach-Object { Write-Host $_ }

Write-Step 'C) Asıl haber hiç ulaşmıyor; tekrar aralıkları geçici 1,2,3,4,5 sn'
$settings = Get-SimSettings -Problems @{ ReplayRate = 100 }
for ($i = 0; $i -lt 5; $i++) { $settings["Webhooks__RetryDelaysSeconds__$i"] = $i+1 }
Restart-Simulator $settings
$numbers = New-Invoices 5
$list = InList $numbers
Wait-InvoicesIn $numbers @('Gönderildi') 60 | Out-Null
Invoke-Compose @('stop', '-t', '0', 'invoice-service')
Wait-EventsDone $numbers 120 | Out-Null
Show-ErpQuery "SELECT invoice_number, event_type, kind, status, first_sent_at, attempt_count FROM webhook_deliveries WHERE invoice_number IN ($list) ORDER BY invoice_number, id;"
$failed = Count-Erp "SELECT count(*) FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'Normal' AND status = 'Failed' AND attempt_count = 6;"
$skipped = Count-Erp "SELECT count(*) FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'Replay' AND status = 'Skipped' AND first_sent_at IS NULL AND attempt_count = 0;"
Check 'C: 10 asıl haber Failed/6 deneme; 5 eski haber Skipped/0 deneme/boş first_sent_at' "$failed / $skipped" ($failed -eq 10 -and $skipped -eq 5)
Invoke-Compose @('start', 'invoice-service')
Wait-Service

Write-Step 'D) Sahte haber %100; geçici Docker dinleyicisi önce 500, sonra 401 dönüyor'
$shell = @'
#!/bin/sh
while IFS= read -r line; do
  [ "$line" = "$(printf '\r')" ] && break
done
status=$(cat /tmp/status)
printf 'HTTP/1.1 %s Test\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' "$status"
'@
[IO.File]::WriteAllText($responder, $shell.Replace("`r`n", "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
& docker run -d --pull never --name $listener --network staj-tasks_apps --entrypoint /bin/sh postgres:17-alpine -c 'sleep 600' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Dinleyici container oluşturulamadı.' }
& docker cp $responder "${listener}:/tmp/respond.sh"
& docker exec $listener sh -c 'chmod +x /tmp/respond.sh; echo 500 > /tmp/status'
& docker exec -d $listener busybox nc -lk -p 8088 -e /tmp/respond.sh
if ($LASTEXITCODE -ne 0) { throw 'Dinleyici başlatılamadı.' }
[IO.File]::WriteAllText($override, "services:`n  erp-simulator:`n    environment:`n      Webhooks__TargetUrl: http://${listener}:8088/`n")
Clear-SimulatorEnv
$settings = Get-SimSettings -Problems @{ FakeRate = 100 }
foreach ($key in $settings.Keys) { Set-Item "Env:$key" ([string]$settings[$key]) }
try { Invoke-Compose @('-f', 'docker-compose.yml', '-f', $override, 'up', '-d', '--force-recreate', 'erp-simulator') } finally { Clear-SimulatorEnv }
Start-Sleep -Seconds 2
$numbers = New-Invoices 3
$list = InList $numbers
$watch = [Diagnostics.Stopwatch]::StartNew()
do {
    $retried = Count-Erp "SELECT count(*) FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'Fake' AND status = 'Pending' AND last_http_status = 500 AND attempt_count >= 2;"
    if ($retried -eq 3) { break }
    if ($watch.Elapsed.TotalSeconds -gt 60) { throw '500 alan sahte haberler tekrar denenmedi.' }
    Start-Sleep -Seconds 1
} while ($true)
Show-ErpQuery "SELECT invoice_number, kind, status, last_http_status, attempt_count FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'Fake' ORDER BY 1;"
Check 'D: 500 alan 3 sahte haber Pending, en az 2 deneme' "$retried" ($retried -eq 3)
& docker exec $listener sh -c 'echo 401 > /tmp/status'
$watch.Restart()
do {
    $rejected = Count-Erp "SELECT count(*) FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'Fake' AND status = 'Rejected' AND last_http_status = 401;"
    if ($rejected -eq 3) { break }
    if ($watch.Elapsed.TotalSeconds -gt 100) { throw '401 alan sahte haberler Rejected olmadı.' }
    Start-Sleep -Seconds 1
} while ($true)
$before = Count-Erp "SELECT sum(attempt_count) FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'Fake';"
Start-Sleep -Seconds 12
$after = Count-Erp "SELECT sum(attempt_count) FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'Fake';"
Show-ErpQuery "SELECT invoice_number, kind, status, last_http_status, attempt_count FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'Fake' ORDER BY 1;"
Check 'D: 401 alan 3 sahte haber Rejected; 12 sn sonra deneme sayısı aynı' "$rejected; $before -> $after" ($rejected -eq 3 -and $before -eq $after)
# Normal haberler 401 için de tekrar denenir; ortamı geri almadan önce hepsi sonuçlansın.
Wait-EventsDone $numbers 240 | Out-Null
Cleanup
Write-Result $allPassed 'A-D: gerçek oluşma sırası, teslim sonrası eski haber, başarısız asılda atlama, yalnızca 4xx kalıcı red'
Stop-Transcript | Out-Null
if (-not $allPassed) { exit 1 }
