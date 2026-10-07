# Elle takip açma ve kapatma. Servis çalışırken kullanılır; Docker komutlarını bu script çalıştırmaz.
. "$PSScriptRoot\_common.ps1"

Write-Title 'Elle takip: açma, eşzamanlı istek, kapatma ve okuma'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
$numbers = @(New-Invoices 3)
$stuck, $race, $fresh = $numbers
Wait-InvoicesIn $numbers @('Onaylandı', 'Reddedildi') 180 'kesin durumda' | Out-Null
Wait-EventsDone $numbers 120 | Out-Null
Invoke-ServiceSql ("UPDATE invoices SET status = 'Gönderildi', reject_reason = NULL, updated_at = now() - interval '10 minutes' WHERE invoice_number IN ('$stuck', '$race'); " +
                   "UPDATE invoices SET status = 'Gönderildi', reject_reason = NULL, updated_at = now() WHERE invoice_number = '$fresh';") | Out-Null
$minutes = (Get-Api '/api/v1/invoices/summary').Json.stuckAfterMinutes
$beforeAction = Get-LastActionId
$beforeFollowUps = Count-Service 'SELECT count(*) FROM invoice_follow_ups;'

Write-DbHeader 'A) Başlıksız takip isteği'
$missingHeader = Send-OperatorPost "/api/v1/invoices/$stuck/follow-up" '{"note":"Kontrol ediliyor"}'
Show-ServiceQuery "SELECT count(*) AS takip FROM invoice_follow_ups WHERE invoice_number = '$stuck'; SELECT count(*) AS islem FROM operator_actions WHERE id > $beforeAction;"
Check (Write-DbVerdict '400 operator_name_required; takip ve operator_actions yazılmadı' "$($missingHeader.Status) $($missingHeader.Code); yeni işlem $((Get-LastActionId) - $beforeAction); takip $((Count-Service 'SELECT count(*) FROM invoice_follow_ups;') - $beforeFollowUps)" `
    ($missingHeader.Status -eq 400 -and $missingHeader.Code -eq 'operator_name_required' -and (Get-LastActionId) -eq $beforeAction -and (Count-Service 'SELECT count(*) FROM invoice_follow_ups;') -eq $beforeFollowUps))

Write-DbHeader 'B) Takibe alma ve ikinci istek'
$opened = Send-OperatorPost "/api/v1/invoices/$stuck/follow-up" '{"note":"ERP kararı bekleniyor"}' -Name 'Ayşe Yılmaz'
$duplicate = Send-OperatorPost "/api/v1/invoices/$stuck/follow-up" '{"note":"İkinci istek"}' -Name 'Mehmet'
Show-ServiceQuery "SELECT id, invoice_number, operator_name, note, opened_at, closed_at, closed_by FROM invoice_follow_ups WHERE invoice_number = '$stuck' ORDER BY id; SELECT operator_name, action, invoice_number, result FROM operator_actions WHERE invoice_number = '$stuck' ORDER BY id;"
Check (Write-DbVerdict 'ilk istek 201, ikincisi 409 follow_up_open' "$($opened.Status), $($duplicate.Status) $($duplicate.Code)" ($opened.Status -eq 201 -and $duplicate.Status -eq 409 -and $duplicate.Code -eq 'follow_up_open'))
$openAction = @(Get-ServiceRows "SELECT action, result FROM operator_actions WHERE invoice_number = '$stuck' ORDER BY id;")
Check (Write-DbVerdict 'takip ve açma işlemi kaydı veritabanında' "$((Count-Service "SELECT count(*) FROM invoice_follow_ups WHERE invoice_number = '$stuck' AND closed_at IS NULL;")) takip; $($openAction -join ' / ')" `
    ((Count-Service "SELECT count(*) FROM invoice_follow_ups WHERE invoice_number = '$stuck' AND closed_at IS NULL;") -eq 1 -and $openAction -contains 'Takibe Alma|Takibe alındı' -and $openAction -contains 'Takibe Alma|Reddedildi: zaten takipte (Ayşe Yılmaz)'))

Write-DbHeader 'C) Aynı faturaya aynı anda iki takip isteği'
$path = "$ServiceUrl/api/v1/invoices/$race/follow-up"
$send = {
    param($operator)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $path)
    $request.Content = [Net.Http.StringContent]::new('{"note":"Eşzamanlı kontrol"}', [Text.Encoding]::UTF8, 'application/json')
    $request.Headers.TryAddWithoutValidation('X-Operator-Name', [Uri]::EscapeDataString($operator)) | Out-Null
    $script:BareHttp.SendAsync($request)
}
$t1 = & $send 'Ayşe'; $t2 = & $send 'Mehmet'
$r1 = Receive-Api $t1; $r2 = Receive-Api $t2
$responses = @($r1, $r2)
$successes = @($responses | Where-Object { $_.Status -eq 201 })
$refusals = @($responses | Where-Object { $_.Status -eq 409 })
Show-ServiceQuery "SELECT id, invoice_number, operator_name, opened_at FROM invoice_follow_ups WHERE invoice_number = '$race' AND closed_at IS NULL; SELECT operator_name, action, result FROM operator_actions WHERE invoice_number = '$race' ORDER BY id;"
$raceActions = @(Get-ServiceRows "SELECT result FROM operator_actions WHERE invoice_number = '$race' ORDER BY id;")
$raceOpenCount = Count-Service "SELECT count(*) FROM invoice_follow_ups WHERE invoice_number = '$race' AND closed_at IS NULL;"
Check (Write-DbVerdict 'eşzamanlı iki isteğin biri 201, diğeri 409; tek açık takip' "$($r1.Status), $($r2.Status); açık takip $raceOpenCount" ($successes.Count -eq 1 -and $refusals.Count -eq 1 -and $raceOpenCount -eq 1))
Check (Write-DbVerdict 'operator_actions içinde başarılı ve reddedilen istek' "$($raceActions -join ' / ')" ($raceActions.Count -eq 2 -and @($raceActions | Where-Object { $_ -eq 'Takibe alındı' }).Count -eq 1 -and @($raceActions | Where-Object { $_ -like 'Reddedildi: zaten takipte (*)' }).Count -eq 1))
Write-DbHeader 'D) Takılı olmayan faturaya takip isteği'
$notStuck = Send-OperatorPost "/api/v1/invoices/$fresh/follow-up" '{"note":"Takılı değil"}' -Name 'Ayşe Yılmaz'
Show-ServiceQuery "SELECT invoice_number, status, updated_at FROM invoices WHERE invoice_number = '$fresh'; SELECT operator_name, action, result FROM operator_actions WHERE invoice_number = '$fresh' ORDER BY id;"
$notStuckFollowUps = Count-Service "SELECT count(*) FROM invoice_follow_ups WHERE invoice_number = '$fresh';"
$notStuckActions = Count-Service "SELECT count(*) FROM operator_actions WHERE invoice_number = '$fresh' AND action = 'Takibe Alma' AND result = 'Reddedildi: fatura takılı değil (Gönderildi)';"
Check (Write-DbVerdict '409 invoice_not_stuck; takip yok' "$($notStuck.Status) $($notStuck.Code); takip $notStuckFollowUps" ($notStuck.Status -eq 409 -and $notStuck.Code -eq 'invoice_not_stuck' -and $notStuckFollowUps -eq 0))
Check (Write-DbVerdict 'takılı değil reddi operator_actions içinde' "$notStuckActions kayıt" ($notStuckActions -eq 1))
Write-DbHeader 'E) Takip açıkken takılı sayısı: özet = stuck=true listesi = veritabanı'
$stable = $false
for ($i = 0; $i -lt 30; $i++) {
    $before = @(Get-ServiceRows ((Get-StuckSql $minutes) + ' ORDER BY 1;'))
    $list = Get-StuckList
    $summary = (Get-Api '/api/v1/invoices/summary').Json
    $after = @(Get-ServiceRows ((Get-StuckSql $minutes) + ' ORDER BY 1;'))
    if (($before -join ',') -eq ($after -join ',') -and $summary.stuckCount -eq $after.Count -and $list.Total -eq $after.Count -and ($list.Numbers -join ',') -eq (@($after | Sort-Object) -join ',')) { $stable = $true; break }
    Start-Sleep -Seconds 1
}
$dbCount = $after.Count
Show-ServiceQuery ((Get-StuckSql $minutes 'invoice_number, status, updated_at') + ' ORDER BY invoice_number;')
Check (Write-DbVerdict "takılı sayısı $dbCount; takipteki $stuck ve $race takılı kalıyor" "özet $($summary.stuckCount), liste $($list.Total), DB $dbCount" `
    ($stable -and $summary.stuckCount -eq $dbCount -and $list.Total -eq $dbCount -and $list.Numbers.Count -eq $dbCount -and $list.Numbers -contains $stuck -and $list.Numbers -contains $race))
$followed = (Get-Api "/api/v1/invoices?search=$stuck&pageSize=1").Json.items[0].followedBy
Check (Write-DbVerdict "liste followedBy = Ayşe Yılmaz" "$followed" ($followed -eq 'Ayşe Yılmaz'))

Write-DbHeader 'F) Başka operatör açık takibi kapatıyor'
$closed = Send-OperatorPost "/api/v1/invoices/$stuck/follow-up/close" -Name 'Mehmet'
Show-ServiceQuery "SELECT id, invoice_number, operator_name, opened_at, closed_at, closed_by FROM invoice_follow_ups WHERE invoice_number = '$stuck' ORDER BY id; SELECT operator_name, action, result FROM operator_actions WHERE invoice_number = '$stuck' ORDER BY id;"
Check (Write-DbVerdict '200; takip kapanış zamanı ve kapatan yazıldı' "$($closed.Status); DB kapatan $(@(Get-ServiceRows "SELECT closed_by FROM invoice_follow_ups WHERE invoice_number = '$stuck' AND closed_at IS NOT NULL;")[0])" `
    ($closed.Status -eq 200 -and (Count-Service "SELECT count(*) FROM invoice_follow_ups WHERE invoice_number = '$stuck' AND closed_at IS NOT NULL AND closed_by = 'Mehmet';") -eq 1))

Write-DbHeader 'G) Fatura detayında açık takip ve geçmiş kayıtları'
$detail = Get-Api "/api/v1/invoices/$stuck/details"
Show-ServiceQuery "SELECT id, operator_name, note, opened_at, closed_at, closed_by FROM invoice_follow_ups WHERE invoice_number = '$stuck' ORDER BY opened_at DESC;"
Check (Write-DbVerdict 'detayda followUp=null, followUps geçmiş kaydı içeriyor' "followUp=$($detail.Json.followUp); geçmiş=$(@($detail.Json.followUps).Count); not=$($detail.Json.followUps[0].note)" `
    ($detail.Status -eq 200 -and $null -eq $detail.Json.followUp -and @($detail.Json.followUps).Count -eq 1 -and $detail.Json.followUps[0].closedBy -eq 'Mehmet'))

Write-Result $allPassed 'Elle takip'
