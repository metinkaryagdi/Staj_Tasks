# Gün 23 script'lerinin ortak yardımcıları. Gün 22'nin _common.ps1'ini yükler (token alma, Set-Erp, satır okuma, Wait-Until dahil).
# Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun22\_common.ps1"

# Bu güne özel volume'ler (staj-tasks_*-db-data-gun23); eski volume'lere dokunulmaz.
Use-Gun10Volumes 'gun23'

# Çıktılar günün klasörüne yazılır.
$OutputDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'output\gun23'
New-Item -ItemType Directory -Force $OutputDir | Out-Null

function Get-InvoiceStatus([string]$Number) { Invoke-InvoiceSql "SELECT status FROM invoices WHERE invoice_number = '$Number'" }

# ERP'nin GET cevabındaki karar; GET'te hata davranışı yok.
function Get-ErpDecision([string]$Number) { (Invoke-RestMethod "http://localhost:5080/api/v1/invoices/$Number").decision }

function Show-Invoice([string]$Number) {
    Show-Rows 'Servis (invoices):' "SELECT invoice_number, status, erp_reference, send_attempt_count AS deneme, left(last_error, 60) AS son_hata FROM invoices WHERE invoice_number = '$Number'"
    Show-Rows 'Servis (erp_outbox):' "SELECT $OutboxColumns FROM erp_outbox WHERE invoice_number = '$Number' ORDER BY id"
    Show-Rows 'ERP (fatura ve iptal kayıtları):' ("SELECT 'fatura' AS kayit, erp_reference AS referans FROM invoices WHERE invoice_number = '$Number' " +
        "UNION ALL SELECT 'iptal', cancel_reference FROM cancellations WHERE invoice_number = '$Number'") -Erp
}

function Show-Deliveries([string]$Number) {
    Show-Rows 'ERP (webhook_deliveries):' ("SELECT event_type, kind, status, to_char(occurred_at AT TIME ZONE 'Europe/Istanbul', 'HH24:MI:SS.MS') AS oldugu_an, " +
        "to_char(due_at AT TIME ZONE 'Europe/Istanbul', 'HH24:MI:SS') AS gonderim FROM webhook_deliveries WHERE invoice_number = '$Number' ORDER BY id") -Erp
}

function Show-Events([string]$Number) {
    Show-Rows 'Servis (erp_webhook_events):' ("SELECT event_type, status, ignore_reason, delivery_count AS gelis, " +
        "to_char(received_at AT TIME ZONE 'Europe/Istanbul', 'HH24:MI:SS.MS') AS geldi FROM erp_webhook_events WHERE invoice_number = '$Number' ORDER BY received_at")
}

# Elle imzalanmış ERP haberi.
function Send-SignedEvent([string]$EventId, [string]$Type, [string]$Number, [string]$Reference) {
    $body = [Text.Encoding]::UTF8.GetBytes((New-WebhookBody $EventId $Type $Number $Reference $null))
    $timestamp = Get-UnixNow
    Send-Webhook $body $timestamp (Get-WebhookSignature (Get-DotEnvValue 'ERP_WEBHOOK_SECRET') $timestamp $body)
}

# Mutabakatı başlatır ve bitmesini bekler.
function Invoke-Reconciliation {
    $token = Get-UserToken 'operator'
    $run = Send-Api POST '/api/v1/reconciliation-runs' $token
    if ($run.Status -ne 202) { throw "Mutabakat başlatılamadı: HTTP $($run.Status) $($run.Body)" }
    $deadline = (Get-Date).AddMinutes(10)
    do {
        Start-Sleep -Seconds 2
        $state = (Send-Api GET "/api/v1/reconciliation-runs/$($run.Json.id)" (Get-UserToken 'operator')).Json.run
    } while ($state.status -eq 'Çalışıyor' -and (Get-Date) -lt $deadline)
    $state
}
