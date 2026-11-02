# Kontrol listesi 7: düzeltmelerden sonra kısa yük testi (saniyede 50 fatura, 2 dakika). Kayıp ve çift kayıt veritabanlarından
# sayılır; pano Grafana'dan (admin girişiyle), metrikler ve alarmlar Prometheus'tan ve Alertmanager'dan izleme-girisi
# üzerinden (operator'ün izleme-girisi token'ıyla) okunur. Alarm zincirinin uçtan uca çalıştığını görmek için yük sürerken
# yanlış imzalı 25 ERP haberi gönderilir: CokSayida401 tetiklenmeli ve alert-receiver'ın loguna düşmeli.
# Çıktı manual-tests\output\gun21\<-Etiket>.txt. ~8 dk (kuyruğun boşalması dahil).
#   .\manual-tests\gun21\2-yuk-testi.ps1
param([string]$Etiket = 'c-yuk-testi', [int]$Rate = 50, [string]$Duration = '2m')
. "$PSScriptRoot\_common.ps1"

New-Report $Etiket
Write-Title "Yük testi: saniyede $Rate fatura, $Duration"
Start-Stack
$runId = "GUN21-YUK-$(Get-Date -Format 'yyyyMMddTHHmmss')"
Write-Line "Koşu: $(Get-Date -Format 'yyyy-MM-dd HH:mm'), RUN_ID $runId"

# İzleme araçlarına giriş kapısından, operator'ün izleme-girisi token'ıyla gidilir; token 5 dk yaşadığı için her sorguda
# 4 dakikadan eskiyse yenisi alınır.
$script:MonitoringToken = $null; $script:MonitoringTokenAt = [datetime]::MinValue
function Get-Monitoring([string]$Url) {
    if (((Get-Date) - $script:MonitoringTokenAt).TotalMinutes -gt 4) {
        $script:MonitoringToken = (Get-AuthCodeTokens -ClientId 'izleme-girisi' -Redirect 'http://localhost:9090/oauth2/callback' -Scope 'openid' `
            -UserName 'operator' -Password $TestUsers['operator'] -ClientSecret (Get-DotEnvValue 'MONITORING_CLIENT_SECRET')).Access
        $script:MonitoringTokenAt = Get-Date
    }
    $r = Send-Http GET $Url @{ Authorization = "Bearer $script:MonitoringToken" }
    if ($r.Status -ne 200) { throw "HTTP $($r.Status): $Url" }
    $r.Body | ConvertFrom-Json
}
function Get-PromValue([string]$Query) {
    $rows = @((Get-Monitoring "http://localhost:9090/api/v1/query?query=$([Uri]::EscapeDataString($Query))").data.result)
    if ($rows.Count -eq 0) { return $null }
    [double]::Parse($rows[0].value[1], [Globalization.CultureInfo]::InvariantCulture)
}

# alert-receiver'ın logundaki alarm satırları; $Since (UTC, yyyy-MM-dd HH:mm:ss) sonrası.
function Get-ReceiverLines([string]$Since) {
    Push-Location $RepoRoot
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $lines = @(& docker compose logs alert-receiver --no-log-prefix 2>$null | ForEach-Object { "$_" } | Where-Object { $_ -match 'Alert status=' }) }
    finally { $ErrorActionPreference = $previous; Pop-Location }
    @($lines | Where-Object { $_.Length -ge 19 -and $_.Substring(0, 19) -ge $Since })
}

$createdBefore = Get-PromValue 'sum(invoices_created_total)'
$since = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')

Write-Line ''
Write-Line "1) k6 (compose'daki k6 servisi, sipariş sisteminin token'ı)"
$env:RATE = "$Rate"; $env:DURATION = $Duration; $env:RUN_ID = $runId
Push-Location $RepoRoot
$k6Job = Start-Job -ScriptBlock { param($root, $composeFile, $vol, $rate, $duration, $run)
    Set-Location $root; $env:COMPOSE_FILE = $composeFile; $env:GUN10_VOL = $vol; $env:RATE = $rate; $env:DURATION = $duration; $env:RUN_ID = $run
    docker compose --profile yuk-testi run --rm k6 2>&1 } -ArgumentList $RepoRoot, $env:COMPOSE_FILE, $env:GUN10_VOL, "$Rate", $Duration, $runId
Pop-Location

# Yük sürerken: yanlış imzalı 25 haber (CokSayida401'in eşiği 5 dakikada 20).
Start-Sleep -Seconds 30
$codes = 1..25 | ForEach-Object {
    $body = [Text.Encoding]::UTF8.GetBytes((New-WebhookBody "gun21-401-$_-$(Get-Random)" 'invoice.received' 'FTR-000001' 'ERP-1' $null))
    (Send-Webhook $body (Get-UnixNow) ('0' * 64)).Status
}
Write-Line "  Yük sürerken yanlış imzalı 25 ERP haberi: $(($codes | Group-Object | ForEach-Object { "HTTP $($_.Name) x $($_.Count)" }) -join ', ')"

$k6Out = Receive-Job $k6Job -Wait -AutoRemoveJob
$k6File = Join-Path $RepoRoot "load-test\results\$runId.json"
$k6 = Get-Content $k6File -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Line "  k6: $($k6.requests) istek, $($k6.accepted) kabul (202); 401 alan istek $($k6.unauthorized401), p95 $([Math]::Round($k6.durationMs.p95, 1)) ms"

Write-Line ''
Write-Line '2) Kuyruğun boşalması'
$runJoin = "FROM erp_outbox o JOIN invoices i ON i.invoice_number = o.invoice_number WHERE i.customer_code = '$runId'"
$deadline = (Get-Date).AddMinutes(20)
do {
    $pending = [int]@(Get-ServiceRows "SELECT count(*) $runJoin AND o.status = 'Bekliyor';")[0]
    if ($pending -gt 0) { Start-Sleep -Seconds 15 }
} while ($pending -gt 0 -and (Get-Date) -lt $deadline)
Check ($pending -eq 0) "Kuyrukta bekleyen: $pending ($(Get-Date -Format 'HH:mm:ss'))"

Write-Line ''
Write-Line '3) Kayıp ve çift kayıt (veritabanları)'
$row = @(Get-ServiceRows ("SELECT count(*) || '|' || count(*) FILTER (WHERE o.status = 'Tamamlandı') || '|' || " +
    "count(*) FILTER (WHERE o.status = 'Başarısız') $runJoin;"))[0] -split '\|'
$created = [int]$row[0]; $completed = [int]$row[1]; $failed = [int]$row[2]
$completedNumbers = @(Get-ServiceRows "SELECT o.invoice_number $runJoin AND o.status = 'Tamamlandı';" | Where-Object { $_ -match '^FTR-' })
$erp = @(Get-ErpRows "SELECT count(DISTINCT invoice_number) || '|' || count(*) FROM invoices WHERE customer_code = '$runId';")[0] -split '\|'
$dupes = [int]@(Get-ErpRows "SELECT count(*) FROM (SELECT invoice_number FROM invoices WHERE customer_code = '$runId' GROUP BY 1 HAVING count(*) > 1) d;")[0]
$erpNumbers = [Collections.Generic.HashSet[string]]::new([string[]]@(Get-ErpRows "SELECT DISTINCT invoice_number FROM invoices WHERE customer_code = '$runId';" | Where-Object { $_ -match '^FTR-' }))
$notAtErp = @($completedNumbers | Where-Object { -not $erpNumbers.Contains($_) }).Count
Write-Line "  Serviste bu koşunun faturası: $created (gönderimi tamamlanan $completed, başarısız $failed)"
Write-Line "  ERP'de: $($erp[0]) farklı fatura numarası, $($erp[1]) kayıt"
Check (($k6.accepted - $created) -eq 0) "k6'nın 202 aldığı ama serviste olmayan: $($k6.accepted - $created)"
Check ($notAtErp -eq 0) "Serviste gönderimi tamamlanmış ama ERP'de kaydı olmayan: $notAtErp"
Check ($dupes -eq 0) "ERP'de birden fazla kaydı olan fatura numarası: $dupes"

Write-Line ''
Write-Line '4) Mutabakat ve veritabanı yetkileri (uygulamalar invoice_app / erp_app ile)'
$operatorApi = Get-UserToken 'operator'
$run = Send-Api POST '/api/v1/reconciliation-runs' $operatorApi
$reconciliationRunId = $run.Json.id
$deadline = (Get-Date).AddMinutes(5)
do {
    $runState = (Send-Api GET "/api/v1/reconciliation-runs/$reconciliationRunId" $operatorApi).Json.run
    if ($runState.status -eq 'Çalışıyor') { Start-Sleep -Seconds 3 }
} while ($runState.status -eq 'Çalışıyor' -and (Get-Date) -lt $deadline)
Check ($runState.status -eq 'Tamamlandı') "Mutabakat (POST /api/v1/reconciliation-runs, HTTP $($run.Status)): çalışma $reconciliationRunId $($runState.status); kontrol edilen $($runState.checkedCount), düzeltilen $($runState.fixedCount), raporlanan $($runState.reportedCount)"
# PostgreSQL yetki hatasını "42501: permission denied" diye yazar; yalnız "42501" loglardaki rastgele kimliklerin içinde de geçer.
Push-Location $RepoRoot
$permissionErrors = @(docker compose logs --since 30m invoice-service erp-simulator 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'permission denied|42501:' })
Pop-Location
Check ($permissionErrors.Count -eq 0) "Son 30 dk'da invoice-service ve erp-simulator loglarında yetki hatası (permission denied / 42501): $($permissionErrors.Count)"

Write-Line ''
# Mutabakattan sonra: "Bulgular" paneli yalnız son bir saatte bulgu varsa veri gösterir.
Write-Line '5) Pano ve metrikler'
$createdAfter = Get-PromValue 'sum(invoices_created_total)'
Check (($createdAfter - $createdBefore) -eq $created) "Prometheus (izleme-girisi üzerinden): invoices_created_total artışı $($createdAfter - $createdBefore), serviste $created"
$down = @((Get-Monitoring 'http://localhost:9090/api/v1/targets').data.activeTargets | Where-Object { $_.health -ne 'up' })
Check ($down.Count -eq 0) "Prometheus'un toplama hedefleri: $(@((Get-Monitoring 'http://localhost:9090/api/v1/targets').data.activeTargets).Count) hedef, up olmayan $($down.Count)"
$grafanaAuth = @{ Authorization = (Get-BasicAuth 'admin' (Get-DotEnvValue 'GRAFANA_ADMIN_PASSWORD')) }
$dashboards = (Send-Http GET 'http://localhost:3000/api/search?type=dash-db' $grafanaAuth).Body | ConvertFrom-Json
$dashboard = (Send-Http GET "http://localhost:3000/api/dashboards/uid/$($dashboards[0].uid)" $grafanaAuth).Body | ConvertFrom-Json
$panels = @($dashboard.dashboard.panels | Where-Object { $_.targets })
# Her panelin her sorgusu; panel, sorgularından en az biri veri döndürüyorsa veri gösteriyor sayılır (bir paneldeki "hata"
# serisi sorunsuz bir koşuda boş olabilir).
$queries = 0; $failedQueries = @()
$emptyPanels = @(foreach ($panel in $panels) {
    $withData = 0
    foreach ($target in @($panel.targets | Where-Object { $_.expr })) {
        $queries++
        $q = Send-Http GET "http://localhost:3000/api/datasources/proxy/uid/prometheus/api/v1/query_range?query=$([Uri]::EscapeDataString($target.expr))&start=$([DateTimeOffset]::UtcNow.AddMinutes(-15).ToUnixTimeSeconds())&end=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())&step=15" $grafanaAuth
        if ($q.Status -ne 200) { $failedQueries += "$($panel.title) (HTTP $($q.Status))" }
        elseif (@(($q.Body | ConvertFrom-Json).data.result).Count -gt 0) { $withData++ }
    }
    if ($withData -eq 0) { $panel.title }
})
Check ($failedQueries.Count -eq 0) "Grafana panosu '$($dashboard.dashboard.title)' (admin girişiyle): $($panels.Count) panelin $queries sorgusu Grafana'nın veri kaynağından soruldu, hata veren sorgu $($failedQueries.Count)$(if ($failedQueries) { ': ' + ($failedQueries -join ', ') })"
Check ($emptyPanels.Count -eq 0) "  son 15 dk'da verisi olmayan panel: $($emptyPanels.Count)$(if ($emptyPanels) { ': ' + ($emptyPanels -join ', ') })"

Write-Line ''
Write-Line '6) Alarmlar'
$groups = (Get-Monitoring 'http://localhost:9090/api/v1/rules').data.groups
$rules = @($groups | ForEach-Object { $_.rules })
Check (@($rules | Where-Object { $_.health -ne 'ok' }).Count -eq 0) "Prometheus'taki alarm kuralları: $($rules.Count), sağlıksız $(@($rules | Where-Object { $_.health -ne 'ok' }).Count)"
$ams = @((Get-Monitoring 'http://localhost:9090/api/v1/alertmanagers').data.activeAlertmanagers)
Check ($ams.Count -eq 1) "Prometheus'un bağlı olduğu Alertmanager: $(($ams | ForEach-Object { $_.url }) -join ', ')"
$deadline = (Get-Date).AddMinutes(3)
do {
    $lines = @(Get-ReceiverLines $since | Where-Object { $_ -match 'alertname=CokSayida401 ' -and $_ -match 'status=firing' })
    if ($lines.Count -eq 0) { Start-Sleep -Seconds 10 }
} while ($lines.Count -eq 0 -and (Get-Date) -lt $deadline)
Check ($lines.Count -gt 0) "CokSayida401 alert-receiver'ın logunda (firing): $(if ($lines) { $lines[0].Substring(0, [Math]::Min(160, $lines[0].Length)) } else { 'yok' })"
$amAlerts = @(Get-Monitoring 'http://localhost:9093/api/v2/alerts' | Where-Object { $_.labels.alertname -eq 'CokSayida401' })
Write-Line "  Alertmanager'da (izleme-girisi üzerinden) CokSayida401: $($amAlerts.Count) kayıt, durum $(($amAlerts | ForEach-Object { $_.status.state }) -join ', ')"

Write-Line ''
Write-Line "Sonuç: $(if ($script:AllPassed) { 'bütün kontroller TAMAM' } else { 'FARKLI satırlar var' })"
Save-Report
