# Kontrol listesi 1: operatör bir faturayı yeniden gönderdiğinde operator_actions'ta kullanıcı adıyla birlikte sub da
# var. Bütün yığın bu güne özel volume'lerle yeniden oluşturulur (Keycloak realm'i keycloak/'tan kurar). ~8 dk: yeniden
# gönderilecek Başarısız fatura için simülatör kısa süre yalnızca 500 döndürür (10 deneme), sonra varsayılan ayarlarına
# döner. Volume'ler ilk oluşturulduklarında boştur; boş veritabanıyla yeniden koşmak için önce
# staj-tasks_erp-db-data-gun18 ve staj-tasks_invoice-db-data-gun18 silinir.
#   .\manual-tests\gun18\1-sub.ps1
. "$PSScriptRoot\_common.ps1"

New-Report 'gun18-1-sub'
Write-Title 'Kontrol listesi 1) operator_actions''ta kullanıcı adıyla birlikte sub'

Write-Step 'docker compose up -d --build --force-recreate (gun18 volume''leri)'
Clear-SimulatorEnv
Invoke-Compose @('up', '-d', '--build', '--force-recreate')
Wait-KeycloakAndService
$runId = 'GUN18-SUB-' + (Get-Date -Format 'yyyyMMdd-HHmmss')

try {
    Write-Step 'Başarısız fatura hazırlanıyor (simülatör yalnızca 500)'
    Restart-Simulator @{ Simulator__Rates__Success = 0; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 100
        Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0 }
    $created = Send-Api POST '/api/v1/invoices' (Get-OrderSystemToken) "{""customerCode"":""$runId"",""amount"":10.5,""currency"":""TRY"",""invoiceDate"":""2026-10-23""}"
    if ($created.Status -ne 202) { throw "Fatura oluşturulamadı: HTTP $($created.Status) $($created.Body)" }
    $n = $created.Json.invoiceNumber
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (@(Get-ServiceRows "SELECT status FROM invoices WHERE invoice_number = '$n';")[0] -ne 'Başarısız') {
        if ($watch.Elapsed.TotalMinutes -gt 15) { throw "$n 15 dakikada Başarısız olmadı." }
        Start-Sleep -Seconds 10
    }
    Write-Line "$n $(Format-Duration $watch.Elapsed.TotalSeconds) sonra Başarısız oldu."
}
finally { Restart-Simulator }

Write-Step "Operatör $n'i yeniden gönderiyor"
$operator = Get-UserToken 'operator'
$claims = Get-TokenClaims $operator
$r = Send-Api POST "/api/v1/invoices/$n/resend" $operator
Write-Line "POST /api/v1/invoices/$n/resend (operatör token'ı): HTTP $($r.Status), fatura $($r.Json.status)"
Write-Line "Token: preferred_username=$($claims.preferred_username) sub=$($claims.sub)"

$sql = "SELECT id, operator_name, operator_sub, action, invoice_number, result, to_char(created_at, 'HH24:MI:SS') AS saat FROM operator_actions WHERE invoice_number = '$n' ORDER BY id;"
Write-Line ''
Write-Line "Veritabanı: $sql"
$rows = @(Get-ServiceRows $sql)
foreach ($row in $rows) { Write-Line "  $row" }
$columns = if ($rows.Count -eq 1) { $rows[0] -split '\|' } else { @() }
Write-Line ''
Check ($r.Status -eq 202) "yeniden gönderme HTTP $($r.Status)"
Check ($rows.Count -eq 1 -and $columns[1] -eq 'operator') "operator_actions'ta tek satır, operator_name = $($columns[1])"
Check ($rows.Count -eq 1 -and $columns[2] -ne '') "aynı satırda operator_sub = $($columns[2])"
Save-Report
Write-Result $script:AllPassed 'Yeniden gönderme operator_actions''a kullanıcı adıyla birlikte sub ile yazıldı.'
