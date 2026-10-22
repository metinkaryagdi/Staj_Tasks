# Kontrol listesi 3: operatör bir faturayı yeniden gönderdiğinde operator_actions'a token'daki kullanıcı adı yazılıyor;
# istekte başka bir ad gönderilse de kayıt değişmiyor. Açık yığında çalışır. ~7 dk: yeniden gönderilecek Başarısız fatura
# için simülatör kısa süre yalnızca 500 döndürür (10 deneme), sonra varsayılan ayarlarına döner.
#   .\manual-tests\gun17\3-operator-adi.ps1
. "$PSScriptRoot\_common.ps1"

New-Report 'gun17-3-operator-adi'
Write-Title 'Kontrol listesi 3) operator_actions''a token''daki ad yazılıyor'
Wait-KeycloakAndService
$runId = 'GUN17-OPERATOR-' + (Get-Date -Format 'yyyyMMdd-HHmmss')

try {
    Write-Step 'Başarısız fatura hazırlanıyor (simülatör yalnızca 500)'
    Restart-Simulator @{ Simulator__Rates__Success = 0; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 100
        Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0 }
    $created = Send-Api POST '/api/v1/invoices' (Get-OrderSystemToken) "{""customerCode"":""$runId"",""amount"":10.5,""currency"":""TRY"",""invoiceDate"":""2026-10-22""}"
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

Write-Step "Operatör $n'i yeniden gönderiyor; istekte X-Operator-Name: sahte"
$operator = Get-UserToken 'operator'
$before = [long]@(Get-ServiceRows 'SELECT coalesce(max(id), 0) FROM operator_actions;')[0]
$r = Send-Api POST "/api/v1/invoices/$n/resend" $operator $null @{ 'X-Operator-Name' = 'sahte' }
Write-Line "POST /api/v1/invoices/$n/resend (operatör token'ı, X-Operator-Name: sahte): HTTP $($r.Status), fatura $($r.Json.status)"
Write-Line "Token'daki ad (preferred_username): $((Get-TokenClaims $operator).preferred_username)"

$sql = "SELECT id, operator_name, action, invoice_number, result, to_char(created_at, 'HH24:MI:SS') AS saat FROM operator_actions WHERE id > $before ORDER BY id;"
Write-Line ''
Write-Line "Veritabanı: $sql"
$rows = @(Get-ServiceRows $sql)
foreach ($row in $rows) { Write-Line "  $row" }
$names = @($rows | ForEach-Object { ($_ -split '\|')[1] })
$passed = $r.Status -eq 202 -and $rows.Count -eq 1 -and $names[0] -eq 'operator' -and -not ($rows -match 'sahte')
Save-Report
Write-Result $passed "Yeniden gönderme 202; operator_actions'ta tek satır, operator_name = operator (istekteki 'sahte' yazılmadı)."
