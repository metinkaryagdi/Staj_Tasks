# İptal: kontrol listesinin dışında kalan, görev mailinin maddelerinden gelen canlı kontroller. TAMAM = beklenen.
#   A) İki servis kopyası (iki worker) çalışırken 60 faturanın iptali aynı anda: her iptal ERP'ye faturadan sonra ulaşır, ERP'de
#      her faturaya tek iptal kaydı olur, ERP hiçbir isteği hız sınırıyla (429 rateLimited) geri çevirmez (Servis 2, 3).
#   B) ERP iptallere Busy, ServerError ve SaveThenError dönerken 20 faturanın iptali: hepsi tamamlanır, ERP'de her faturaya tek
#      iptal kaydı olur (ERP 2, 3; Servis 2).
#   C) Reddedilmiş faturanın iptali 409 invoice_rejected (Servis 5).
#   D) Fatura gönderilirken servis öldürülür, iptal kuyrukta bekler: yeniden açılınca fatura tekrar POST edilmez, iptal
#      faturadan sonra gider (Servis 3).
#   E) ERP'ye aynı faturanın 10 iptal isteği aynı anda (doğrudan ERP'ye): tek iptal kaydı, 10 cevapta aynı referans (ERP 2).
# ~12 dk.
#   .\manual-tests\gun22\3-iptal-ek.ps1
param([string]$Etiket = 'd-iptal-ek')
. "$PSScriptRoot\_common.ps1"

New-Report $Etiket
Write-Title 'İptal: ek canlı kontroller'
Start-Stack
Write-Line "Koşu: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

# Operatör token'ı 4 dakikadan eskiyse yenilenir (bir bölümde onlarca iptal isteği gönderilir).
$script:OperatorToken = $null; $script:OperatorTokenAt = [datetime]::MinValue
function Get-OperatorToken {
    if (((Get-Date) - $script:OperatorTokenAt).TotalMinutes -gt 4) {
        $script:OperatorToken = Get-UserToken 'operator'; $script:OperatorTokenAt = Get-Date
    }
    $script:OperatorToken
}
function Get-Count([string]$Sql) { [int](Invoke-InvoiceSql $Sql) }
function In-List([string[]]$Numbers) { ($Numbers | ForEach-Object { "'$_'" }) -join ',' }
function Get-ErpLog { @(Get-SimulatorLog | ForEach-Object { "$_" }) }

# ---------------------------------------------------------------------------------------------------------------------
Write-Line ''
Write-Line 'A) İki servis kopyası çalışırken 60 faturanın iptali aynı anda: sıra, tek kayıt, hız sınırı'
Push-Location $RepoRoot
try { docker compose --profile iki-kopya up -d --build invoice-service-2 2>&1 | Out-Null } finally { Pop-Location }
Wait-Until { try { (Send-Http GET 'http://localhost:5091/health').Status -eq 200 } catch { $false } } 120 'İkinci kopya (invoice-service-2) açıldı'
Set-Erp @{ Success = 100 }
$a = @(1..60 | ForEach-Object { New-Invoice })
$aList = In-List $a
Wait-Until { (Get-Count "SELECT count(*) FROM erp_outbox WHERE kind = 'Gönderim' AND status = 'Tamamlandı' AND invoice_number IN ($aList)") -eq 60 } 120 '60 fatura ERP''ye ulaştı'
$limitedBefore = @(Get-ErpLog | Where-Object { $_ -match 'reason=rateLimited' }).Count
$started = Get-Date
$answers = @($a | ForEach-Object { (Send-Api POST "/api/v1/invoices/$_/cancel" (Get-OperatorToken)).Status })
Write-Line ("  60 iptal isteği {0:0.0} sn'de gönderildi; cevaplar: {1}" -f ((Get-Date) - $started).TotalSeconds,
    (($answers | Group-Object | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '))
Wait-Until { (Get-Count "SELECT count(*) FROM erp_outbox WHERE kind = 'İptal' AND status = 'Tamamlandı' AND invoice_number IN ($aList)") -eq 60 } 180 '60 iptal satırı Tamamlandı oldu'
$erpCancels = Get-SqlScalar "SELECT count(*) || '/' || count(DISTINCT invoice_number) FROM cancellations WHERE invoice_number IN ($aList)"
Check ($erpCancels -eq '60/60') "ERP'de iptal kaydı / farklı fatura: $erpCancels"
$early = Get-SqlScalar "SELECT count(*) FROM cancellations c WHERE invoice_number IN ($aList) AND c.cancelled_at <= (SELECT min(received_at) FROM invoices i WHERE i.invoice_number = c.invoice_number)"
Check ($early -eq '0') "ERP'de iptali faturasından önce ya da aynı anda kaydedilen fatura: $early"
$perSecond = Get-SqlScalar "SELECT max(n) FROM (SELECT count(*) AS n FROM cancellations WHERE invoice_number IN ($aList) GROUP BY date_trunc('second', cancelled_at)) s"
$limitedAfter = @(Get-ErpLog | Where-Object { $_ -match 'reason=rateLimited' }).Count
Check (($limitedAfter - $limitedBefore) -eq 0) "ERP'nin hız sınırıyla geri çevirdiği istek: $($limitedAfter - $limitedBefore) (ERP sınırı 20/sn, servisin gönderim hızı Outbox:SendsPerSecond = 18); bir saniyede ERP'ye kaydedilen en çok iptal: $perSecond"
Push-Location $RepoRoot
try {
    $byCopy = foreach ($service in 'invoice-service', 'invoice-service-2') {
        $n = @(docker compose --profile iki-kopya logs $service --no-log-prefix 2>$null | Where-Object { $_ -match 'ERP send kind=İptal' -and $_ -match ($a -join '|') }).Count
        "$service $n"
    }
}
finally { Pop-Location }
Write-Line "  İptalleri gönderen kopyalar (log satırı): $($byCopy -join ', ')"

# ---------------------------------------------------------------------------------------------------------------------
Write-Line ''
Write-Line 'B) ERP iptallere Busy, ServerError ve SaveThenError dönerken 20 faturanın iptali'
$b = @(1..20 | ForEach-Object { New-Invoice })
$bList = In-List $b
Wait-Until { (Get-Count "SELECT count(*) FROM erp_outbox WHERE kind = 'Gönderim' AND status = 'Tamamlandı' AND invoice_number IN ($bList)") -eq 20 } 120 '20 fatura ERP''ye ulaştı'
Set-Erp @{ Success = 25; Busy = 25; ServerError = 25; SaveThenError = 25 }
foreach ($n in $b) { [void](Send-Api POST "/api/v1/invoices/$n/cancel" (Get-OperatorToken)) }
Wait-Until { (Get-Count "SELECT count(*) FROM erp_outbox WHERE kind = 'İptal' AND status <> 'Bekliyor' AND invoice_number IN ($bList)") -eq 20 } 420 '20 iptal satırı sonuçlandı'
Check ((Get-Count "SELECT count(*) FROM erp_outbox WHERE kind = 'İptal' AND status = 'Tamamlandı' AND invoice_number IN ($bList)") -eq 20) '20 iptalin hepsi Tamamlandı'
$erpB = Get-SqlScalar "SELECT count(*) || '/' || count(DISTINCT invoice_number) FROM cancellations WHERE invoice_number IN ($bList)"
Check ($erpB -eq '20/20') "ERP'de iptal kaydı / farklı fatura: $erpB"
$bPattern = $b -join '|'
$bLog = @(Get-ErpLog | Where-Object { $_ -match 'ERP cancel request #\d+ invoice=(\S+) behavior=(\w+)' -and $_ -match $bPattern })
$behaviors = $bLog | ForEach-Object { [regex]::Match($_, 'behavior=(\w+)').Groups[1].Value } | Group-Object | ForEach-Object { "$($_.Name) $($_.Count)" }
Write-Line "  ERP'nin iptal isteklerine seçtiği davranışlar: $($behaviors -join ', ')"
$duplicates = @(Get-ErpLog | Where-Object { $_ -match 'ERP cancel invoice=\S+ behavior=Duplicate' -and $_ -match $bPattern }).Count
Write-Line "  Tekrar gelen iptal (ERP'de yeni kayıt açılmadı): $duplicates"
Show-Rows 'İptal satırlarının deneme sayısı:' "SELECT attempt_count AS deneme, count(*) AS iptal FROM erp_outbox WHERE kind = 'İptal' AND invoice_number IN ($bList) GROUP BY attempt_count ORDER BY 1"
Push-Location $RepoRoot
try { $found = @(docker compose --profile iki-kopya logs invoice-service invoice-service-2 --no-log-prefix 2>$null | Where-Object { $_ -match 'ERP send kind=İptal' -and $_ -match 'check=found' -and $_ -match $bPattern }).Count }
finally { Pop-Location }
Write-Line "  ERP'ye sorulup iptali zaten kayıtlı bulunan deneme (SaveThenError'dan sonra, tekrar POST yok): $found"

# ---------------------------------------------------------------------------------------------------------------------
Write-Line ''
Write-Line 'C) Reddedilmiş faturanın iptali'
Set-Erp @{ Success = 100 } @{ 'Webhooks__ApprovalRate' = 0 }
$c = New-Invoice
Wait-Until { (Send-Api GET "/api/v1/invoices/$c" (Get-OperatorToken)).Json.status -eq 'Reddedildi' } 60 "$c Reddedildi oldu"
$rc = Send-Api POST "/api/v1/invoices/$c/cancel" (Get-OperatorToken)
Check ($rc.Status -eq 409 -and $rc.Code -eq 'invoice_rejected') "İptal isteği: HTTP $($rc.Status) $($rc.Code) - $($rc.Json.detail)"
Check ((Get-Count "SELECT count(*) FROM erp_outbox WHERE kind = 'İptal' AND invoice_number = '$c'") -eq 0) 'İptal kuyruğa alınmadı'
Show-Rows 'operator_actions:' "SELECT operator_name, action, result FROM operator_actions WHERE invoice_number = '$c'"

# ---------------------------------------------------------------------------------------------------------------------
Write-Line ''
Write-Line 'D) Fatura gönderilirken servis öldürülüyor, iptal kuyrukta bekliyor'
Push-Location $RepoRoot
try { docker compose --profile iki-kopya stop invoice-service-2 2>&1 | Out-Null } finally { Pop-Location }
Write-Line '  İkinci kopya durduruldu (öldürülen kopyanın lock''unu diğer kopya almasın, yeniden açılan kopya alsın)'
Set-Erp @{ LateResponse = 100 } @{ 'Simulator__LateResponseDelaySeconds' = 40 }
$d = New-Invoice
Wait-Until { (Get-SqlScalar "SELECT count(*) FROM invoices WHERE invoice_number = '$d'") -eq '1' } 60 'ERP faturayı kaydetti, cevabı 40 sn geciktiriyor'
$rd = Send-Api POST "/api/v1/invoices/$d/cancel" (Get-OperatorToken)
Check ($rd.Status -eq 202) "Fatura gönderilirken iptal isteği: HTTP $($rd.Status)"
Show-Rows 'Öldürmeden hemen önce (erp_outbox):' "SELECT $OutboxColumns FROM erp_outbox WHERE invoice_number = '$d' ORDER BY id"
Push-Location $RepoRoot
try { docker compose kill invoice-service 2>&1 | Out-Null; docker compose up -d invoice-service 2>&1 | Out-Null } finally { Pop-Location }
Write-Line "  invoice-service öldürüldü ve yeniden açıldı $(Get-Date -Format 'HH:mm:ss')"
Wait-KeycloakAndService
Wait-Until { (Get-Outbox $d 'İptal') -like 'Tamamlandı|*' } 240 'Fatura ve iptal tamamlandı'
Check ((Get-SqlScalar "SELECT count(*) FROM invoices WHERE invoice_number = '$d'") -eq '1') "ERP'de $d için fatura kaydı: 1 (yeniden açılan servis faturayı ERP'ye sordu, tekrar POST etmedi)"
Check ((Get-SqlScalar "SELECT count(*) FROM cancellations WHERE invoice_number = '$d'") -eq '1') "ERP'de $d için iptal kaydı: 1"
$orderD = Get-SqlScalar "SELECT (SELECT min(received_at) FROM invoices WHERE invoice_number = '$d') < (SELECT cancelled_at FROM cancellations WHERE invoice_number = '$d')"
Check ($orderD -eq 't') "ERP'de faturanın kaydı iptalin kaydından önce: $orderD"
Show-Rows 'ERP veritabanı:' ("SELECT 'fatura' AS kayit, to_char(received_at AT TIME ZONE 'Europe/Istanbul', 'HH24:MI:SS.MS') AS zaman FROM invoices WHERE invoice_number = '$d' " +
    "UNION ALL SELECT 'iptal', to_char(cancelled_at AT TIME ZONE 'Europe/Istanbul', 'HH24:MI:SS.MS') FROM cancellations WHERE invoice_number = '$d' ORDER BY zaman") -Erp
Show-Rows 'Servis veritabanı (erp_outbox):' "SELECT $OutboxColumns FROM erp_outbox WHERE invoice_number = '$d' ORDER BY id"
# Bir isteğin davranış satırı (behavior=) tek; bağlantısı kopan isteğin "client disconnected" satırı ayrıca yazılır.
$posts = @(Get-ErpLog | Where-Object { $_ -match "ERP request #\d+ invoice=$d behavior=" }).Count
Check ($posts -eq 1) "ERP'ye ulaşan fatura POST'u: $posts"

# ---------------------------------------------------------------------------------------------------------------------
Write-Line ''
Write-Line 'E) ERP''ye aynı faturanın 10 iptal isteği aynı anda'
Set-Erp @{ Success = 100 }
Push-Location $RepoRoot
try { docker compose --profile iki-kopya stop invoice-service 2>&1 | Out-Null } finally { Pop-Location }
Write-Line '  Fatura Servisi durduruldu (iptali yalnız bu bölümün istekleri göndersin)'
$e = "GUN22-E-$(Get-Date -Format 'HHmmss')"
$saved = Send-Http POST "$BaseUrl/api/v1/invoices" @{} (@{ invoiceNumber = $e; customerCode = 'C-022'; amount = 10.5; currency = 'TRY'; invoiceDate = '2026-11-03' } | ConvertTo-Json)
Check ($saved.Status -eq 202) "ERP'ye doğrudan fatura ${e}: HTTP $($saved.Status)"
$client = [Net.Http.HttpClient]::new()
$tasks = @(1..10 | ForEach-Object { $client.PostAsync("$BaseUrl/api/v1/invoices/$e/cancel", $null) })
[Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks)
$codes = @($tasks | ForEach-Object { [int]$_.Result.StatusCode })
$refs = @($tasks | ForEach-Object { ($_.Result.Content.ReadAsStringAsync().Result | ConvertFrom-Json).cancelReference } | Sort-Object -Unique)
Write-Line "  10 cevap: $(($codes | Group-Object | ForEach-Object { "HTTP $($_.Name) x$($_.Count)" }) -join ', '); farklı iptal referansı: $($refs -join ', ')"
Check (@($codes | Where-Object { $_ -ne 202 }).Count -eq 0 -and $refs.Count -eq 1) '10 isteğin hepsi 202 ve aynı referans'
$erpE = Get-SqlScalar "SELECT count(*) FROM cancellations WHERE invoice_number = '$e'"
Check ($erpE -eq '1') "ERP'de $e için iptal kaydı: $erpE"
$eLog = @(Get-ErpLog | Where-Object { $_ -match "ERP cancel (request #\d+ )?invoice=$e behavior=" })
Write-Line "  ERP logu: yeni iptal $(@($eLog | Where-Object { $_ -match 'request #' }).Count), tekrar (Duplicate) $(@($eLog | Where-Object { $_ -match 'behavior=Duplicate' }).Count)"
Push-Location $RepoRoot
try { docker compose up -d invoice-service 2>&1 | Out-Null } finally { Pop-Location }
Wait-KeycloakAndService
Write-Line '  Fatura Servisi yeniden açıldı'

Save-Report
