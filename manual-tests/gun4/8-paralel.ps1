# Gün 4 - Kontrol listesi 8: aynı haberi aynı anda 10 kez paralel gönder: haber yalnızca bir kez işleniyor. ~30 sn.
# Fatura simülatöre Webhooks:Enabled = false ile gönderilir: simülatörün kendi haberleri araya girmesin.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: $_ - simülatör varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Restart-Simulator } catch { }; break }

Write-Title 'Kontrol listesi 8) Aynı haber aynı anda 10 kez paralel'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
Restart-Simulator (Get-SimSettings -NoEvents)
$since = [datetime]::UtcNow.AddSeconds(-1)
$number = @(New-Invoices 1)[0]
Wait-InvoicesIn @($number) @('Gönderildi') 30 'Gönderildi' | Out-Null
$reference = @(Get-ServiceRows "SELECT erp_reference FROM invoices WHERE invoice_number = '$number';")[0]
$eventId = "paralel-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Write-Host "  $number Gönderildi, erp_reference=$reference; haber: $eventId (invoice.received)"

$secret = Get-WebhookSecret
$body = [Text.Encoding]::UTF8.GetBytes((New-WebhookBody $eventId 'invoice.received' $number $reference))
$ts = "$(Get-UnixNow)"
$sig = Get-WebhookSignature $secret $ts $body
$tasks = @()
for ($i = 0; $i -lt 10; $i++) {
    $request = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post, "$ServiceUrl/api/v1/erp-webhooks")
    $request.Content = New-Object System.Net.Http.ByteArrayContent (,$body)
    $request.Content.Headers.ContentType = 'application/json'
    [void]$request.Headers.TryAddWithoutValidation('X-Erp-Timestamp', $ts)
    [void]$request.Headers.TryAddWithoutValidation('X-Erp-Signature', $sig)
    $tasks += $script:Http.SendAsync($request)
}
[Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks)
$codes = @($tasks | ForEach-Object { [int]$_.Result.StatusCode })
$bodies = @($tasks | ForEach-Object { $_.Result.Content.ReadAsStringAsync().GetAwaiter().GetResult() })
Write-Host "  HTTP kodları: $($codes -join ', ')"
$bodies | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

Start-Sleep -Milliseconds 300
Write-Host ''
Write-Host '  Servis logu:' -ForegroundColor Cyan
$log = @(Get-WebhookLog $since | Where-Object { $_ -match "event=$eventId " })
$log | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

Write-DbHeader 'Fatura Servisi'
Show-ServiceQuery "SELECT event_id, event_type, status, delivery_count, to_char(received_at, 'HH24:MI:SS.MS') AS geldi, to_char(processed_at, 'HH24:MI:SS.MS') AS islendi FROM erp_webhook_events WHERE event_id = '$eventId';"
Show-ServiceQuery "SELECT invoice_number, status FROM invoices WHERE invoice_number = '$number';"
$row = @(Get-ServiceRows "SELECT count(*) || '|' || max(status) || '|' || max(delivery_count) FROM erp_webhook_events WHERE event_id = '$eventId';")[0]
$status = @(Get-ServiceRows "SELECT status FROM invoices WHERE invoice_number = '$number';")[0]
$stored = @($log | Where-Object { $_ -match 'webhook stored' }).Count
$repeat = @($log | Where-Object { $_ -match 'webhook repeat' }).Count
$first = @($bodies | Where-Object { $_ -match '"repeat":false' }).Count

Check (Write-DbVerdict '10 istek de 200' ($codes -join ',') ($codes.Count -eq 10 -and @($codes | Where-Object { $_ -ne 200 }).Count -eq 0))
Check (Write-DbVerdict 'yalnızca 1 cevap repeat=false (işleyen), 9''u repeat=true' "$first işleyen" ($first -eq 1))
Check (Write-DbVerdict 'tabloda 1 satır | İşlendi | delivery_count 10' $row ($row -eq '1|İşlendi|10'))
Check (Write-DbVerdict 'logda 1 stored, 9 repeat' "$stored stored, $repeat repeat" ($stored -eq 1 -and $repeat -eq 9))
Check (Write-DbVerdict 'fatura bir kez ilerledi: İşleme Alındı' $status ($status -eq 'İşleme Alındı'))

Restart-Simulator
Write-Result $allPassed 'aynı haber 10 kez paralel geldi, yalnızca biri işledi'
