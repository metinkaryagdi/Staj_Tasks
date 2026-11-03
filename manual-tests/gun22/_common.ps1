# Gün 22 script'lerinin ortak yardımcıları. Gün 21'in _common.ps1'ini yükler (token alma, Send-Http, Keycloak yönetim
# API'si, psql, Start-Stack dahil). Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun21\_common.ps1"

# Bu güne özel volume'ler (staj-tasks_*-db-data-gun22); eski volume'lere dokunulmaz.
Use-Gun10Volumes 'gun22'

# Çıktılar günün klasörüne yazılır.
$OutputDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'output\gun22'
New-Item -ItemType Directory -Force $OutputDir | Out-Null

# İptal script'lerinin yardımcıları. Simülatör olay sorunları kapalı, karar onay, olaylar 1-2 sn içinde başlatılır
# (Set-Erp); satırlar iki veritabanından okunur.
$Events = @{
    'Webhooks__ApprovalRate' = 100; 'Webhooks__FirstEventMinSeconds' = 1; 'Webhooks__FirstEventMaxSeconds' = 2
    'Webhooks__SecondEventMinSeconds' = 1; 'Webhooks__SecondEventMaxSeconds' = 2; 'Webhooks__Problems__DuplicateRate' = 0
    'Webhooks__Problems__OrderMixRate' = 0; 'Webhooks__Problems__LostDecisionRate' = 0; 'Webhooks__Problems__FakeRate' = 0
    'Webhooks__Problems__ReplayRate' = 0
}
function Set-Erp([hashtable]$Rates, [hashtable]$Extra = @{}) {
    $settings = $Events.Clone()
    foreach ($b in 'Success', 'Busy', 'ServerError', 'SaveThenError', 'LateResponse') { $settings["Simulator__Rates__$b"] = [int]$Rates[$b] }
    foreach ($k in $Extra.Keys) { $settings[$k] = $Extra[$k] }
    Restart-Simulator $settings
    foreach ($k in $Events.Keys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
    Write-Line "  ERP ayarı: $(($Rates.Keys | ForEach-Object { "$_=$($Rates[$_])" }) -join ', ') $(($Extra.Keys | ForEach-Object { "$_=$($Extra[$_])" }) -join ', ')"
}

function Invoke-InvoiceSql([string]$Sql) {
    Push-Location $RepoRoot
    try { ((& docker compose exec -T invoice-db psql -U invoice -d invoice_service -tAc $Sql) | Out-String).Trim() }
    finally { Pop-Location }
}
function Show-Rows([string]$Title, [string]$Sql, [switch]$Erp) {
    Write-Line "  $Title"
    Push-Location $RepoRoot
    try {
        $rows = if ($Erp) { & docker compose exec -T erp-db psql -U erp -d erp_simulator -c $Sql }
                else { & docker compose exec -T invoice-db psql -U invoice -d invoice_service -c $Sql }
    }
    finally { Pop-Location }
    foreach ($row in $rows) { if ("$row".Trim()) { Write-Line "    $row" } }
}
function Wait-Until([scriptblock]$Condition, [int]$TimeoutSeconds, [string]$What) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $Condition)) {
        if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw "$What $TimeoutSeconds sn içinde olmadı." }
        Start-Sleep -Seconds 1
    }
    Write-Line ("  ({0} {1:0} sn sonra)" -f $What, $watch.Elapsed.TotalSeconds)
}

function New-Invoice {
    $r = Send-Api POST '/api/v1/invoices' (Get-OrderSystemToken) '{"customerCode":"C-022","amount":125.50,"currency":"TRY","invoiceDate":"2026-11-03"}'
    if ($r.Status -ne 202) { throw "Fatura oluşturulamadı: HTTP $($r.Status) $($r.Body)" }
    $r.Json.invoiceNumber
}
function Request-Cancel([string]$Number) { Send-Api POST "/api/v1/invoices/$Number/cancel" (Get-UserToken 'operator') }
function Get-Outbox([string]$Number, [string]$Kind) {
    Invoke-InvoiceSql "SELECT status || '|' || attempt_count FROM erp_outbox WHERE invoice_number = '$Number' AND kind = '$Kind'"
}
$OutboxColumns = "kind, status, attempt_count AS deneme, to_char(created_at AT TIME ZONE 'Europe/Istanbul', 'HH24:MI:SS') AS kuyruga, " +
    "to_char(processed_at AT TIME ZONE 'Europe/Istanbul', 'HH24:MI:SS.MS') AS bitti, locked_by, left(last_error, 70) AS son_hata"
