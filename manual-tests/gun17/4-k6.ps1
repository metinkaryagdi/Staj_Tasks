# Kontrol listesi 4: k6 yük testi sipariş sistemi client'ının token'ıyla çalışır, token'ın geçerlilik süresinden (5 dk) uzun
# sürer; süresi dolan token yenilenir, hiçbir istek 401 almaz. Açık yığında çalışır. ~8 dk (load-test/invoices.js,
# saniyede 50 fatura, 7 dk).
#   .\manual-tests\gun17\4-k6.ps1
param([string]$Duration = '7m')

. "$PSScriptRoot\_common.ps1"

New-Report 'gun17-4-k6'
Write-Title "Kontrol listesi 4) k6, sipariş sistemi token'ıyla, $Duration"
Wait-KeycloakAndService
$lifetime = (Get-TokenClaims (Get-OrderSystemToken)).exp - (Get-TokenClaims (Get-OrderSystemToken)).iat
Write-Line "Sipariş sistemi token'ının ömrü: $lifetime sn; test süresi: $Duration."

$runId = 'GUN17-K6-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$result = Invoke-LoadTest @{ DURATION = $Duration; RUN_ID = $runId }

Write-Line ''
Write-Line ("k6 {0}: {1} istek, {2} kabul (202), {3} başka; p95 {4:N1} ms" -f $runId, $result.requests, $result.accepted,
    $result.notAccepted, $result.durationMs.p95)
Write-Line ("VU (en çok): {0}; alınan token: {1}; 401 alan istek: {2}" -f $result.vusMax, $result.tokensFetched, $result.unauthorized401)
Write-Line "Sonuç dosyası: load-test/results/$runId.json"
$seconds = [int]($Duration.TrimEnd('m', 's')) * $(if ($Duration.EndsWith('m')) { 60 } else { 1 })
$renewed = $result.tokensFetched -gt $result.vusMax
Write-Line ("Test süresi token ömründen uzun: {0} ({1} sn > {2} sn); token sayısı VU sayısından büyük (yenilendi): {3}" -f
    $(if ($seconds -gt $lifetime) { 'evet' } else { 'hayır' }), $seconds, $lifetime, $(if ($renewed) { 'evet' } else { 'hayır' }))
Save-Report
Write-Result ($seconds -gt $lifetime -and $renewed -and $result.unauthorized401 -eq 0 -and $result.notAccepted -eq 0) `
    "Token'lar test sırasında yenilendi ($($result.tokensFetched) token, $($result.vusMax) VU) ve hiçbir istek 401 almadı."
