# Kontrol listesi 6: izleyicinin token'ıyla, ekran dışından bir müdahale endpoint'ine elle istek: 403. Token, ekrana
# izleyiciyle giriş yapılmış tarayıcıdan kopyalanır: Geliştirici Araçları > Network > Fatura Servisi'ne giden bir istek
# (örn. summary) > Request Headers > Authorization'daki "Bearer " sonrası. Token 5 dk geçerlidir; kopyalandıktan hemen
# sonra çalıştırılır. Açık yığında çalışır.
#   .\manual-tests\gun18\6-izleyici-403.ps1 -Token '<kopyalanan token>'
param([Parameter(Mandatory)][string]$Token)
. "$PSScriptRoot\_common.ps1"

New-Report 'gun18-6-izleyici-403'
Write-Title 'Kontrol listesi 6) İzleyici token''ıyla ekran dışından müdahale isteği'
# Yapıştırırken gelen boşluk, "Bearer " ve örnekteki < > işaretleri atılır.
$Token = $Token.Trim().Trim('<', '>') -replace '^Bearer\s+', ''
$claims = Get-TokenClaims $Token
Write-Line ("Token: preferred_username={0} client={1} roller={2} bitiş={3}" -f $claims.preferred_username, $claims.azp,
    (@($claims.realm_access.roles | Where-Object { $_ -like 'fatura-*' }) -join ','),
    (Format-Local ([DateTimeOffset]::FromUnixTimeSeconds($claims.exp))))

$r = Send-Api POST '/api/v1/invoices/FTR-000001/resend' $Token
Write-Line "POST /api/v1/invoices/FTR-000001/resend -> HTTP $($r.Status)"
if ($r.WwwAuthenticate) { Write-Line "  WWW-Authenticate: $($r.WwwAuthenticate)" }
Write-Line ''
Check ($claims.preferred_username -eq 'izleyici') 'token izleyicinin'
Check ($r.Status -eq 403) "HTTP $($r.Status)"
Save-Report
Write-Result $script:AllPassed 'İzleyicinin token''ıyla ekran dışından yapılan müdahale isteği 403 aldı.'
