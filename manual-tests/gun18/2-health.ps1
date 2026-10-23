# Kontrol listesi 2: /health token olmadan 200 dönüyor, cevapta iç bilgi yok. Açık yığında çalışır. Birkaç saniye.
#   .\manual-tests\gun18\2-health.ps1
. "$PSScriptRoot\_common.ps1"

New-Report 'gun18-2-health'
Write-Title 'Kontrol listesi 2) /health token''sız'
Wait-KeycloakAndService

$r = Send-Api GET '/health'
Write-Line 'GET /health (Authorization başlığı yok)'
Write-Line "  HTTP $($r.Status)"
Write-Line "  Gövde: $($r.Body)"
$fields = @($r.Json | ForEach-Object { $_.PSObject.Properties.Name })
Write-Line ''
Check ($r.Status -eq 200) "token'sız HTTP $($r.Status)"
Check ($fields.Count -eq 1 -and $fields[0] -eq 'status' -and $r.Json.status -eq 'ok') "gövdede yalnız status = ok (alanlar: $($fields -join ', '))"
Save-Report
Write-Result $script:AllPassed '/health token olmadan 200 dönüyor, cevapta yalnız servisin ayakta olduğu var.'
