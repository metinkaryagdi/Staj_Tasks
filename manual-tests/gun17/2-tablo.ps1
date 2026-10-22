# Kontrol listesi 2: korunan her endpoint için token yok, imzası bozulmuş token, süresi dolmuş token, rolü olmayan kullanıcı,
# izleyici, operatör ve sipariş sistemi durumlarında dönen cevap. Açık yığında çalışır (1-hazir.ps1'den sonra). ~6 dk:
# süresi dolmuş token sütunu için token'ın ömrü (5 dk) ve servisin toleransı (30 sn) beklenir.
#   .\manual-tests\gun17\2-tablo.ps1
# Beklenen: token yok / bozuk / süresi dolmuş -> 401; rol yetmiyorsa 403; rol yetiyorsa 401 ve 403 dışında bir cevap
# (200, 202, 404, 409 ...: istek kimlik ve rol kontrolünden geçmiş, cevap işin kendisinden).
. "$PSScriptRoot\_common.ps1"

New-Report 'gun17-2-tablo'
Write-Title 'Kontrol listesi 2) Endpoint x durum tablosu'
Wait-KeycloakAndService

# Süresi dolmuş token: en başta alınır, tablonun geri kalanı bu sırada doldurulur.
$expiring = Get-UserToken 'operator'
$expiresAt = [DateTimeOffset]::FromUnixTimeSeconds((Get-TokenClaims $expiring).exp)

$tokens = [ordered]@{
    'Token yok'       = $null
    'İmzası bozuk'    = New-TamperedToken (Get-UserToken 'operator')
    'Süresi dolmuş'   = $expiring
    'Rolsüz'          = Get-UserToken 'rolsuz'
    'İzleyici'        = Get-UserToken 'izleyici'
    'Operatör'        = Get-UserToken 'operator'
    'Sipariş sistemi' = Get-OrderSystemToken
}

# Okuma ve müdahale istekleri için bir fatura (sipariş sistemi oluşturur).
$created = Send-Api POST '/api/v1/invoices' $tokens['Sipariş sistemi'] '{"customerCode":"GUN17-TABLO","amount":10.5,"currency":"TRY","invoiceDate":"2026-10-22"}'
if ($created.Status -ne 202) { throw "Tablo için fatura oluşturulamadı: HTTP $($created.Status) $($created.Body)" }
$n = $created.Json.invoiceNumber
Write-Line "Tablo faturası: $n (sipariş sistemi oluşturdu, Bekliyor)."

# Kural: hangi rolün yettiği (Api/Auth/Roles.cs). Any: varsayılan kural, geçerli token yeter.
$rows = @(
    @{ Endpoint = 'POST /api/v1/invoices';                 Rule = 'CreateInvoice'; M = 'POST'; P = '/api/v1/invoices'; B = '{"customerCode":"GUN17-TABLO","amount":10.5,"currency":"TRY","invoiceDate":"2026-10-22"}' }
    @{ Endpoint = 'GET /api/v1/invoices';                  Rule = 'Read';          M = 'GET';  P = '/api/v1/invoices' }
    @{ Endpoint = 'GET /api/v1/invoices/summary';          Rule = 'Read';          M = 'GET';  P = '/api/v1/invoices/summary' }
    @{ Endpoint = 'GET /api/v1/invoices/{n}/details';      Rule = 'Read';          M = 'GET';  P = "/api/v1/invoices/$n/details" }
    @{ Endpoint = 'GET /api/v1/invoices/{n}';              Rule = 'Read';          M = 'GET';  P = "/api/v1/invoices/$n" }
    @{ Endpoint = 'POST /api/v1/invoices/{n}/resend';      Rule = 'Intervene';     M = 'POST'; P = "/api/v1/invoices/$n/resend" }
    @{ Endpoint = 'POST /api/v1/invoices/resend';          Rule = 'Intervene';     M = 'POST'; P = '/api/v1/invoices/resend'; B = "{""invoiceNumbers"":[""$n""]}" }
    @{ Endpoint = 'POST /api/v1/invoices/{n}/follow-up';   Rule = 'Intervene';     M = 'POST'; P = "/api/v1/invoices/$n/follow-up"; B = '{"note":"tablo"}' }
    @{ Endpoint = 'POST /api/v1/invoices/{n}/follow-up/close'; Rule = 'Intervene'; M = 'POST'; P = "/api/v1/invoices/$n/follow-up/close" }
    @{ Endpoint = 'POST /api/v1/reconciliation-runs';      Rule = 'Intervene';     M = 'POST'; P = '/api/v1/reconciliation-runs' }
    @{ Endpoint = 'GET /api/v1/reconciliation-runs';       Rule = 'Read';          M = 'GET';  P = '/api/v1/reconciliation-runs' }
    @{ Endpoint = 'GET /api/v1/reconciliation-runs/{id}';  Rule = 'Read';          M = 'GET';  P = '/api/v1/reconciliation-runs/1' }
    @{ Endpoint = 'GET /health';                           Rule = 'Any';           M = 'GET';  P = '/health' }
    @{ Endpoint = 'GET /openapi/v1.json';                  Rule = 'Any';           M = 'GET';  P = '/openapi/v1.json' }
    @{ Endpoint = 'GET /swagger/index.html';               Rule = 'Any';           M = 'GET';  P = '/swagger/index.html' }
)
$allowed = @{
    CreateInvoice = @('Sipariş sistemi')
    Read          = @('İzleyici', 'Operatör')
    Intervene     = @('Operatör')
    Any           = @('Rolsüz', 'İzleyici', 'Operatör', 'Sipariş sistemi')
}

# Beklenen: 401 (kimlik yok), 403 (rol yetmiyor) ya da "geçer" (401/403 dışı).
function Get-Expected([string]$Rule, [string]$Case) {
    if ($Case -in 'Token yok', 'İmzası bozuk', 'Süresi dolmuş') { return '401' }
    if ($Case -in $allowed[$Rule]) { 'geçer' } else { '403' }
}
function Test-Cell([string]$Expected, [int]$Status) {
    if ($Expected -eq 'geçer') { $Status -notin 401, 403 } else { $Status -eq [int]$Expected }
}

$results = @{}
$reasons = @{}
function Invoke-Column([string]$Case) {
    foreach ($row in $rows) {
        $json = if ($row.ContainsKey('B')) { $row.B } else { $null }
        $r = Send-Api $row.M $row.P $tokens[$Case] $json
        $results["$($row.Endpoint)|$Case"] = $r.Status
        if ($r.Status -eq 401 -and $r.WwwAuthenticate -match 'error_description="([^"]+)"') { $reasons[$Case] = $Matches[1] }
    }
}

Write-Step 'Sütunlar dolduruluyor (süresi dolmuş token hariç)'
foreach ($case in $tokens.Keys) { if ($case -ne 'Süresi dolmuş') { Invoke-Column $case } }

$wait = [math]::Ceiling(($expiresAt.AddSeconds($ClockSkewSeconds + 2) - [DateTimeOffset]::UtcNow).TotalSeconds)
if ($wait -gt 0) {
    Write-Step "Süresi dolmuş token için $wait sn bekleniyor (bitiş $($expiresAt.ToLocalTime().ToString('HH:mm:ss')) + $ClockSkewSeconds sn tolerans)"
    Start-Sleep -Seconds $wait
}
Invoke-Column 'Süresi dolmuş'

# Tablo: her hücrede gelen kod; beklenenden farklıysa yanında "beklenen".
$cases = @($tokens.Keys)
$failures = 0
$md = [Collections.Generic.List[string]]::new()
$md.Add('| Endpoint | ' + ($cases -join ' | ') + ' |')
$md.Add('|---|' + (($cases | ForEach-Object { '---' }) -join '|') + '|')
foreach ($row in $rows) {
    $cells = foreach ($case in $cases) {
        $status = $results["$($row.Endpoint)|$case"]
        $expected = Get-Expected $row.Rule $case
        if (Test-Cell $expected $status) { "$status" } else { $script:failures++; "**$status** (beklenen $expected)" }
    }
    $md.Add("| ``$($row.Endpoint)`` | " + ($cells -join ' | ') + ' |')
}
$mdFile = Join-Path $OutputDir 'gun17-2-tablo.md'
[IO.File]::WriteAllLines($mdFile, $md, [Text.UTF8Encoding]::new($true))

Write-Line ''
foreach ($line in $md) { Write-Line $line }
Write-Line ''
Write-Line '401 nedenleri (WWW-Authenticate):'
foreach ($case in 'Token yok', 'İmzası bozuk', 'Süresi dolmuş') {
    Write-Line ("  {0,-14} {1}" -f $case, $(if ($reasons.ContainsKey($case)) { $reasons[$case] } else { '(açıklama yok: token gönderilmedi)' }))
}
Write-Line ''
Write-Line "Hücre: $($rows.Count * $cases.Count), beklenenden farklı: $failures. Tablo: $mdFile"
Save-Report
Write-Result ($failures -eq 0) "Korunan $($rows.Count) endpoint x $($cases.Count) durumun hepsi beklenen cevabı verdi."
