# Gün 7 - Adım 2: müdahaleyi kimin yaptığı (X-Operator-Name, operator_actions, reconciliation_runs.started_by). ~1 dk.
#
#   A) Başlık yok / boş / yalnızca boşluk: üç istek de 400, operator_actions'a ve faturalara hiçbir şey yazılmıyor.
#   B) Tekli yeniden gönderme: Türkçe karakterli ad (yüzde kodlu) doğru çözülüp kaydediliyor; ikinci deneme 409 ve o da kaydediliyor.
#   C) Toplu yeniden gönderme: her fatura için ayrı kayıt, her biri kendi sonucuyla.
#   D) Mutabakat başlatma: started_by ve kayıt; aynı anda ikinci başlatma 409 ve "başka bir çalışma sürüyor" kaydı.
#   E) Fatura detayı ve çalışma listesi bu bilgileri döndürüyor; CORS ön isteği başlığa izin veriyor.
#
# Önce servisin yeni kodla derlenmiş olması gerekir: docker compose up -d --build invoice-service invoice-service-2
# Veritabanındaki en yeni Başarısız faturalardan 4'ünü kuyruğa alır; worker onları yeniden gönderir.
. "$PSScriptRoot\_common.ps1"

Write-Title 'Adım 2) X-Operator-Name ve operator_actions'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
$failed = @(Get-ServiceRows "SELECT invoice_number FROM invoices WHERE status = 'Başarısız' ORDER BY created_at DESC, invoice_number DESC LIMIT 4;")
if ($failed.Count -lt 4) { throw "Veritabanında en az 4 Başarısız fatura gerekiyor ($($failed.Count) var)." }
$approved = @(Get-ServiceRows "SELECT invoice_number FROM invoices WHERE status = 'Onaylandı' ORDER BY created_at DESC LIMIT 1;")[0]
$missing = 'FTR-999999'
$name = 'Ayşe Yılmaz'
$actionsSql = { param($from) "SELECT id, operator_name, action, invoice_number, result, to_char(created_at, 'HH24:MI:SS') AS saat FROM operator_actions WHERE id > $from ORDER BY id;" }

# --- A) Başlıksız istekler -----------------------------------------------------------------------------------------
Write-DbHeader 'Fatura Servisi' 'A) X-Operator-Name yok, boş ya da yalnızca boşluk: 400, hiçbir şey yazılmıyor'
$before = Get-LastActionId
$runsBefore = Count-Service 'SELECT count(*) FROM reconciliation_runs;'
$single = "/api/v1/invoices/$($failed[0])/resend"
$bulkBody = ConvertTo-ResendBody @($failed[0])
$cases = @(
    @{ What = 'tekli, başlık yok';      R = (Send-OperatorPost $single) },
    @{ What = 'tekli, boş';             R = (Send-OperatorPost $single -Name '' -Raw) },
    @{ What = 'tekli, boşluk';          R = (Send-OperatorPost $single -Name '   ' -Raw) },
    @{ What = 'toplu, başlık yok';      R = (Send-OperatorPost '/api/v1/invoices/resend' $bulkBody) },
    @{ What = 'toplu, boş';             R = (Send-OperatorPost '/api/v1/invoices/resend' $bulkBody -Name '' -Raw) },
    @{ What = 'mutabakat, başlık yok';  R = (Send-OperatorPost '/api/v1/reconciliation-runs') },
    @{ What = 'mutabakat, boşluk';      R = (Send-OperatorPost '/api/v1/reconciliation-runs' -Name '%20%20' -Raw) }
)
foreach ($case in $cases) {
    Check (Write-DbVerdict "$($case.What): 400 operator_name_required" "$($case.R.Status) $($case.R.Code)" `
        ($case.R.Status -eq 400 -and $case.R.Code -eq 'operator_name_required'))
}
$tooLong = Send-OperatorPost $single -Name ('a' * 101)
Check (Write-DbVerdict '101 karakterlik ad: 400 operator_name_invalid' "$($tooLong.Status) $($tooLong.Code)" ($tooLong.Status -eq 400 -and $tooLong.Code -eq 'operator_name_invalid'))
Show-ServiceQuery (& $actionsSql $before)
$stillFailed = Count-Service "SELECT count(*) FROM invoices WHERE invoice_number = '$($failed[0])' AND status = 'Başarısız';"
Check (Write-DbVerdict 'operator_actions''a 0 satır; fatura hâlâ Başarısız; yeni mutabakat çalışması yok' `
    "$((Get-LastActionId) - $before) satır; Başarısız: $stillFailed; yeni çalışma: $((Count-Service 'SELECT count(*) FROM reconciliation_runs;') - $runsBefore)" `
    ((Get-LastActionId) -eq $before -and $stillFailed -eq 1 -and (Count-Service 'SELECT count(*) FROM reconciliation_runs;') -eq $runsBefore))

# --- B) Tekli yeniden gönderme -------------------------------------------------------------------------------------
Write-DbHeader 'Fatura Servisi' "B) Tekli yeniden gönderme '$name' adıyla; aynı fatura ikinci kez"
$before = Get-LastActionId
$first = Send-OperatorPost $single -Name $name
$second = Send-OperatorPost $single -Name $name
Show-ServiceQuery (& $actionsSql $before)
$rows = @(Get-ServiceRows "SELECT operator_name, action, invoice_number, result FROM operator_actions WHERE id > $before ORDER BY id;")
$secondStatus = $second.Json.currentStatus
Check (Write-DbVerdict "ilk istek 202, ikinci 409; 2 satır: '$name' | Yeniden Gönderme | $($failed[0]) | Kuyruğa alındı, sonra Reddedildi: fatura $secondStatus" `
    "$($first.Status), $($second.Status); $($rows.Count) satır: $($rows -join ' / ')" `
    ($first.Status -eq 202 -and $second.Status -eq 409 -and $rows.Count -eq 2 -and
     $rows[0] -eq "$name|Yeniden Gönderme|$($failed[0])|Kuyruğa alındı" -and
     $rows[1] -eq "$name|Yeniden Gönderme|$($failed[0])|Reddedildi: fatura $secondStatus"))

# --- C) Toplu yeniden gönderme -------------------------------------------------------------------------------------
Write-DbHeader 'Fatura Servisi' 'C) Toplu yeniden gönderme: 3 Başarısız, 1 Onaylandı, 1 olmayan numara'
$before = Get-LastActionId
$three = $failed[1..3]
$bulk = Send-OperatorPost '/api/v1/invoices/resend' (ConvertTo-ResendBody @($three + $approved + $missing)) -Name $name
Show-ServiceQuery (& $actionsSql $before)
$rows = @(Get-ServiceRows "SELECT invoice_number, result FROM operator_actions WHERE id > $before AND operator_name = '$name' AND action = 'Toplu Yeniden Gönderme' ORDER BY id;")
$expected = @($three | ForEach-Object { "$_|Kuyruğa alındı" }) + "$approved|Reddedildi: fatura Onaylandı" + "$missing|Fatura bulunamadı"
Check (Write-DbVerdict "200; her fatura için ayrı satır (5): $($expected -join ' / ')" "$($bulk.Status); $($rows.Count) satır: $($rows -join ' / ')" `
    ($bulk.Status -eq 200 -and ($rows -join ',') -eq ($expected -join ',') -and (Get-LastActionId) - $before -eq 5))

# --- D) Mutabakat başlatma -----------------------------------------------------------------------------------------
Write-DbHeader 'Fatura Servisi' 'D) Mutabakat başlatma; aynı anda ikinci başlatma'
$before = Get-LastActionId
# İkisi aynı anda: biri kilidi alır (202), diğeri 409 alır.
$t1 = $script:BareHttp.SendAsync($(
    $r = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, "$ServiceUrl/api/v1/reconciliation-runs")
    $r.Headers.TryAddWithoutValidation('X-Operator-Name', [Uri]::EscapeDataString($name)) | Out-Null; $r))
$t2 = $script:BareHttp.SendAsync($(
    $r = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, "$ServiceUrl/api/v1/reconciliation-runs")
    $r.Headers.TryAddWithoutValidation('X-Operator-Name', 'Mehmet') | Out-Null; $r))
$r1 = Receive-Api $t1; $r2 = Receive-Api $t2
$started = @($r1, $r2) | Where-Object { $_.Status -eq 202 }
$refused = @($r1, $r2) | Where-Object { $_.Status -eq 409 }
$starter = if ($r1.Status -eq 202) { $name } else { 'Mehmet' }
$other = if ($r1.Status -eq 202) { 'Mehmet' } else { $name }
$runId = if ($started) { $started.Json.id } else { 0 }
if ($runId) { Wait-RunDone $runId | Out-Null }
Show-ServiceQuery (& $actionsSql $before)
Show-ServiceQuery "SELECT id, status, started_by FROM reconciliation_runs WHERE id = $runId;"
Check (Write-DbVerdict 'biri 202, diğeri 409 reconciliation_running' "$($r1.Status), $($r2.Status)" (@($started).Count -eq 1 -and @($refused).Count -eq 1 -and $refused.Code -eq 'reconciliation_running'))
$runStartedBy = @(Get-ServiceRows "SELECT started_by FROM reconciliation_runs WHERE id = $runId;")[0]
Check (Write-DbVerdict "çalışma $runId started_by = $starter" "$runStartedBy" ($runStartedBy -eq $starter))
$rows = @(Get-ServiceRows "SELECT operator_name, action, coalesce(invoice_number, '(boş)'), result FROM operator_actions WHERE id > $before ORDER BY id;")
$expectedRows = @("$starter|Mutabakat Başlatma|(boş)|Başlatıldı: çalışma $runId", "$other|Mutabakat Başlatma|(boş)|Reddedildi: başka bir çalışma sürüyor")
Check (Write-DbVerdict "2 satır, invoice_number boş: $($expectedRows -join ' / ')" "$($rows -join ' / ')" `
    ((@($rows | Sort-Object) -join ',') -eq (@($expectedRows | Sort-Object) -join ',')))

# --- E) Okuma ve CORS ----------------------------------------------------------------------------------------------
Write-DbHeader 'Fatura Servisi' 'E) Fatura detayındaki müdahaleler, çalışma listesindeki startedBy, CORS'
$details = Get-Api "/api/v1/invoices/$($failed[0])/details"
$dbActions = @(Get-ServiceRows "SELECT operator_name, action, result FROM operator_actions WHERE invoice_number = '$($failed[0])' ORDER BY id DESC;")
$apiActions = @($details.Json.operatorActions | ForEach-Object { "$($_.operatorName)|$($_.action)|$($_.result)" })
Check (Write-DbVerdict "detayda $($failed[0]) için $($dbActions.Count) müdahale, en yeni üstte: $($dbActions -join ' / ')" "$($apiActions -join ' / ')" `
    (($dbActions -join ',') -eq ($apiActions -join ',')))
$runs = Get-Api '/api/v1/reconciliation-runs'
$listed = @($runs.Json) | Where-Object { $_.id -eq $runId }
Check (Write-DbVerdict "çalışma listesinde $runId startedBy = $starter" "$($listed.startedBy)" ($listed.startedBy -eq $starter))

$preflight = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Options, "$ServiceUrl/api/v1/reconciliation-runs")
$preflight.Headers.Add('Origin', 'http://localhost:5100')
$preflight.Headers.Add('Access-Control-Request-Method', 'POST')
$preflight.Headers.Add('Access-Control-Request-Headers', 'x-operator-name')
$answer = $script:BareHttp.SendAsync($preflight).GetAwaiter().GetResult()
$allowed = $null; $allowedHeaders = if ($answer.Headers.TryGetValues('Access-Control-Allow-Headers', [ref]$allowed)) { $allowed -join ',' } else { '' }
Check (Write-DbVerdict 'ekranın adresinden ön istek: X-Operator-Name başlığına izin var' "Allow-Headers: '$allowedHeaders'" ($allowedHeaders -match '(?i)x-operator-name'))

Write-Result $allPassed 'Adım 2'
