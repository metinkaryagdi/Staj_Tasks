# Gün 4 - FATURA SERVİSİ maddelerinin B1-B4 kanıtları. Uygulama kaynaklarını değiştirmez.
. "$PSScriptRoot\_common.ps1"
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutputDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $OutputDir "gun4-ek-fatura-servisi-$stamp.log"
$evidenceFile = Join-Path $OutputDir "gun4-ek-fatura-servisi-$stamp.csv"
$unitFile = Join-Path $OutputDir "gun4-ek-fatura-servisi-$stamp.trx"
$allPassed = $true
$section = 'B1'
$currentSource = ''
$evidence = New-Object 'System.Collections.Generic.List[object]'
$proofEvents = @{}
$secret = Get-WebhookSecret
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Start-Transcript -Path $log | Out-Null

function Check([string]$Expected, [string]$Actual, [bool]$Passed, [string]$Sql = '') {
    $evidence.Add([pscustomobject]@{
        Section = $script:section; Expected = $Expected; Actual = $Actual; Passed = $Passed
        Code = $script:currentSource; Sql = $Sql
    })
    if (-not (Write-DbVerdict $Expected $Actual $Passed)) { $script:allPassed = $false }
}
function Show-CodeEvidence([string]$Path, [int]$First, [int]$Last) {
    $full = Join-Path $RepoRoot $Path
    Write-Host ("KOD: " + $full + ":" + $First + "-" + $Last) -ForegroundColor DarkGray
    $lines = @(Get-Content -LiteralPath $full -Encoding UTF8)
    for ($i = $First; $i -le [Math]::Min($Last, $lines.Count); $i++) {
        Write-Host ('  {0}: {1}' -f $i, $lines[$i-1]) -ForegroundColor DarkGray
    }
}
function Check-Zero([string]$Name, [string]$Sql) {
    Show-ServiceQuery $Sql
    $count = Count-Service $Sql
    Check "$Name : 0" "$count" ($count -eq 0) $Sql
}
function Show-UnitEvidence([string]$Class) {
    $rows = @($script:unitRows | Where-Object { $_.testName -like "*.$Class.*" })
    $bad = @($rows | Where-Object { $_.outcome -ne 'Passed' }).Count
    Write-Host "UNIT: $Class; kaynak $script:unitFile; $($rows.Count) test, başarısız $bad"
    foreach ($row in $rows) { Write-Host "  $($row.outcome) $($row.testName)" -ForegroundColor DarkGray }
    Check "$Class unit testlerinin hepsi geçti" "$($rows.Count) test / başarısız $bad" ($rows.Count -gt 0 -and $bad -eq 0)
}
function New-ProofEvent([string]$Number, [string]$Type, [string]$Reason = '', [string]$Reference = '') {
    if (-not $Reference) {
        $Reference = [string]@(Get-ServiceRows "SELECT erp_reference FROM invoices WHERE invoice_number = '$Number';")[0]
    }
    if (-not $Reference) { throw "$Number için ERP referansı bulunamadı." }
    $id = 'proof-' + [Guid]::NewGuid().ToString('N')
    [pscustomobject]@{
        Id = $id; Number = $Number; Type = $Type; Reference = $Reference
        Body = New-WebhookBody $id $Type $Number $Reference $Reason
    }
}
function Send-ProofEvent($Event, [int]$AgeSeconds = 0, [switch]$BadSignature, [switch]$NoHeaders) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Event.Body)
    $ts = [string]((Get-UnixNow) - $AgeSeconds)
    $signature = Get-WebhookSignature $script:secret $ts $bytes
    if ($BadSignature) { $signature = '0' * 64 }
    if ($NoHeaders) { $ts = $null; $signature = $null }
    Write-Host "HTTP POST $ServiceUrl/api/v1/erp-webhooks; event_id=$($Event.Id); gövde=$($bytes.Length) bayt"
    if ($bytes.Length -lt 1024) { Write-Host "  İstek: $($Event.Body)" -ForegroundColor DarkGray }
    $response = Send-Webhook $bytes $ts $signature
    Write-Host "  Gelen HTTP $($response.Status): $($response.Body)"
    if ($response.Status -eq 200) { $script:proofEvents[$Event.Id] = $Event }
    $response
}
function Get-ProofInvoice([string]$Number) {
    $url = "$ServiceUrl/api/v1/invoices/$Number"
    $response = $script:Http.GetAsync($url).GetAwaiter().GetResult()
    $json = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    Write-Host "HTTP GET $url -> $([int]$response.StatusCode): $json"
    [pscustomobject]@{ Http = [int]$response.StatusCode; Invoice = ($json | ConvertFrom-Json) }
}
function New-ProofInvoice {
    Write-Host "HTTP POST $ServiceUrl/api/v1/invoices; C-001, 1250.50 TRY"
    $r = New-ServiceInvoice
    Write-Host "  Gelen HTTP $($r.HttpStatus): $($r.Body)"
    if ($r.HttpStatus -ne 202) { throw "Fatura oluşturulamadı: $($r.Body)" }
    $r
}
function Check-Event($Event, [string]$Status, [string]$Reason = '') {
    $sql = "SELECT event_id, event_type, status, ignore_reason, received_at, processed_at FROM erp_webhook_events WHERE event_id = '$($Event.Id)';"
    Show-ServiceQuery $sql
    $row = [string]@(Get-ServiceRows "SELECT status || '|' || coalesce(ignore_reason, '') FROM erp_webhook_events WHERE event_id = '$($Event.Id)';")[0]
    Check "$($Event.Id): $Status / $Reason" $row ($row -eq "$Status|$Reason") $sql
}
function Cleanup {
    Invoke-Compose @('start', 'erp-simulator')
    Restart-Simulator
}
trap {
    Write-Host "Hata: $_ - simülatör varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
    try { Cleanup } catch { Write-Host "Temizlik hatası: $_" -ForegroundColor Red }
    $evidence | Export-Csv -LiteralPath $evidenceFile -Encoding UTF8 -NoTypeInformation
    Write-Result $false 'B1-B4 kanıtları tamamlanamadı; uygulama değiştirilmedi'
    Stop-Transcript | Out-Null
    exit 1
}

Write-Title 'FATURA SERVİSİ - B1-B4 kanıtlı doğrulama'
Write-Step 'Kaynak sürümü ve unit kanıtı'
Push-Location $RepoRoot
try {
    & git log -1 --oneline
    # Testler katman başına bir projede (Domain/Application/Infrastructure/Api.Tests): her proje kendi trx dosyasını yazar.
    Write-Host "KOMUT: dotnet test invoice-service/InvoiceService.slnx --logger trx --results-directory $OutputDir"
    & dotnet test invoice-service/InvoiceService.slnx --logger "trx;LogFilePrefix=$([IO.Path]::GetFileNameWithoutExtension($unitFile))" --results-directory $OutputDir
    if ($LASTEXITCODE -ne 0) { throw 'Fatura Servisi unit testleri başarısız.' }
} finally { Pop-Location }
$unitFiles = @(Get-ChildItem -LiteralPath $OutputDir -Filter "$([IO.Path]::GetFileNameWithoutExtension($unitFile))*.trx")
$unitRows = @($unitFiles | ForEach-Object {
    ([xml](Get-Content -LiteralPath $_.FullName -Raw)).SelectNodes("//*[local-name()='UnitTestResult']") } | ForEach-Object { $_ })
Wait-Service

Write-Title 'B1) Altı durum değeri'
$currentSource = 'InvoiceService.Domain/Invoices/Invoice.cs:36-54; InvoiceService.Infrastructure/Persistence/InvoiceDbContext.cs:26; InvoiceService.Api/Invoices/InvoiceEndpoints.cs:77-90; InvoiceService.Infrastructure/Persistence/Migrations/20261001195409_AddErpWebhookEvents.cs:13-51'
Show-CodeEvidence 'invoice-service/src/InvoiceService.Domain/Invoices/Invoice.cs' 36 54
Show-CodeEvidence 'invoice-service/src/InvoiceService.Infrastructure/Persistence/InvoiceDbContext.cs' 22 40
Show-CodeEvidence 'invoice-service/src/InvoiceService.Api/Invoices/InvoiceEndpoints.cs' 77 90
Show-ServiceQuery "SELECT c.conname, c.convalidated, pg_get_constraintdef(c.oid) AS tanim FROM pg_constraint c WHERE c.conrelid='invoices'::regclass ORDER BY c.conname;"
$constraint = [string]@(Get-ServiceRows "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid='invoices'::regclass AND conname='ck_invoices_status';")[0]
$values = @([regex]::Matches($constraint, "'([^']*)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$statuses = @('Bekliyor', 'Gönderildi', 'İşleme Alındı', 'Onaylandı', 'Reddedildi', 'Başarısız')
Check 'constraint tam olarak altı durum içeriyor' ($values -join ', ') (($values -join '|') -eq (($statuses | Sort-Object) -join '|'))

Write-Step 'Bekliyor için canlı örnek: Busy %100, haberler kapalı'
Restart-Simulator (Get-SimSettings -Behavior 'Busy' -NoEvents)
$pendingInvoice = New-ProofInvoice
Show-ServiceQuery "SELECT i.invoice_number, i.status, o.status AS outbox, o.attempt_count FROM invoices i JOIN erp_outbox o USING(invoice_number) WHERE i.invoice_number='$($pendingInvoice.InvoiceNumber)';"
$pending = [string]@(Get-ServiceRows "SELECT status FROM invoices WHERE invoice_number='$($pendingInvoice.InvoiceNumber)';")[0]
Check 'canlı POST 202 Bekliyor ve veritabanı Bekliyor' "$($pendingInvoice.HttpStatus) / $($pendingInvoice.Status) / $pending" ($pendingInvoice.HttpStatus -eq 202 -and $pendingInvoice.Status -eq 'Bekliyor' -and $pending -eq 'Bekliyor')

Write-Step 'Gönderildi, İşleme Alındı, Onaylandı ve Reddedildi örnekleri; haberler elle imzalanıyor'
Restart-Simulator (Get-SimSettings -NoEvents)
$created = @()
for ($i = 0; $i -lt 4; $i++) { $created += New-ProofInvoice }
$numbers = @($created | ForEach-Object { $_.InvoiceNumber })
Wait-QueueDrained $numbers[0] $numbers[-1] 90 | Out-Null
$approvedNumber = $numbers[0]; $rejectedNumber = $numbers[1]
$processingNumber = $numbers[2]; $directNumber = $numbers[3]
$evApproved = New-ProofEvent $approvedNumber 'invoice.approved'
$evRejected = New-ProofEvent $rejectedNumber 'invoice.rejected' 'Kanıt: vergi numarası geçersiz'
$evProcessing = New-ProofEvent $processingNumber 'invoice.received'
foreach ($ev in @($evApproved, $evRejected, $evProcessing)) {
    $r = Send-ProofEvent $ev
    Check 'kurulum haberi HTTP 200' "$($ev.Id): $($r.Status)" ($r.Status -eq 200)
}
Show-ServiceQuery "SELECT invoice_number,status,erp_reference,reject_reason FROM invoices WHERE invoice_number IN ($(InList $numbers)) ORDER BY 1;"
$actual = @(Get-ServiceRows "SELECT status FROM invoices WHERE invoice_number IN ($(InList $numbers)) ORDER BY invoice_number;")
Check 'dört canlı örnek: Onaylandı/Reddedildi/İşleme Alındı/Gönderildi' ($actual -join ', ') (($actual -join '|') -eq 'Onaylandı|Reddedildi|İşleme Alındı|Gönderildi')
Show-ServiceQuery "SELECT status,count(*) AS satir,min(invoice_number) AS ornek FROM invoices GROUP BY status ORDER BY status;"
$failedCount = Count-Service "SELECT count(*) FROM invoices WHERE status='Başarısız';"
if ($failedCount -gt 0) {
    Show-ServiceQuery "SELECT invoice_number,status,send_attempt_count,last_error FROM invoices WHERE status='Başarısız' ORDER BY invoice_number LIMIT 1;"
    Check 'Başarısız için mevcut veride örnek var' "$failedCount satır; örnek yukarıdaki SQL'den" $true
} else {
    Write-Host 'DOĞRULANMADI: Başarısız örnek yok. ServerError %100 ve Outbox:MaxAttempts=10 tükenene kadar beklenerek üretilebilir.'
    Check 'Başarısız örnek mevcut ya da canlı doğrulanmış' 'doğrulanmadı' $false
}
Check-Zero 'bütün tabloda altı değer dışındaki durum' "SELECT count(*) FROM invoices WHERE status NOT IN ('Bekliyor','Gönderildi','İşleme Alındı','Onaylandı','Reddedildi','Başarısız');"
$probe = Test-ServiceSql "UPDATE invoices SET status='Bilinmiyor' WHERE invoice_number='$approvedNumber';"
Write-Host "KOMUT: BEGIN; UPDATE invoices SET status='Bilinmiyor' WHERE invoice_number='$approvedNumber'; ROLLBACK;"
Write-Host "  Gelen: $($probe.Error)"
Check 'geçersiz UPDATE check constraint ile reddediliyor' "kabul=$($probe.Accepted); $($probe.Error)" (-not $probe.Accepted -and $probe.Error -match 'ck_invoices_status')
foreach ($s in $statuses + @('Bilinmiyor')) {
    $url = "$ServiceUrl/api/v1/invoices?status=$([Uri]::EscapeDataString($s))&pageSize=100"
    $response = $script:Http.GetAsync($url).GetAwaiter().GetResult()
    $json = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $expected = if ($s -eq 'Bilinmiyor') { 400 } else { 200 }
    Write-Host "HTTP GET $url -> $([int]$response.StatusCode)"
    $matches = $true; $count = 0
    if ($expected -eq 200) {
        $items = @(($json | ConvertFrom-Json).items); $count = $items.Count
        $matches = @($items | Where-Object { $_.status -ne $s }).Count -eq 0
    } else { Write-Host "  Gelen: $json" }
    Check "GET status=$s HTTP $expected; gelen satırlar filtreyle uyumlu" "$([int]$response.StatusCode); $count satır" ([int]$response.StatusCode -eq $expected -and $matches)
}
# InvoiceRulesTests katmanlara bölündü; testleri artık bu beş sınıfta.
foreach ($class in 'InvoiceNumberTests', 'CreateInvoiceRequestTests', 'OutboxOptionsTests', 'ErpOptionsTests', 'ShippedSettingsTests') { Show-UnitEvidence $class }
Write-Host 'YORUM: bu unit testler (eski InvoiceRulesTests) doğrudan HTTP durum filtresi veya PostgreSQL constraint testi içermiyor; bu ikisi yukarıda canlı doğrulandı.'

$section = 'B2'
Write-Title 'B2) İleri durum geçişleri ve kesin durumlar'
$currentSource = 'InvoiceService.Domain/Invoices/InvoiceTransitions.cs:26-48; InvoiceService.Application/Webhooks/WebhookEventProcessor.cs:62-76; InvoiceService.Application/Webhooks/InvoiceEventApplier.cs:12-21; InvoiceService.Application/Invoices/CreateInvoiceHandler.cs:35; InvoiceService.Application/Invoices/ResendInvoiceHandler.cs:33-37; InvoiceService.Infrastructure/Persistence/InvoiceStore.cs:40-56; InvoiceService.Infrastructure/Persistence/OutboxStore.cs:10-39; InvoiceService.Application/Outbox/OutboxOutcomeWriter.cs:21-47'
Show-CodeEvidence 'invoice-service/src/InvoiceService.Domain/Invoices/InvoiceTransitions.cs' 26 48
Show-CodeEvidence 'invoice-service/src/InvoiceService.Application/Webhooks/WebhookEventProcessor.cs' 62 76
Show-CodeEvidence 'invoice-service/src/InvoiceService.Application/Webhooks/InvoiceEventApplier.cs' 12 21
Show-CodeEvidence 'invoice-service/src/InvoiceService.Application/Invoices/ResendInvoiceHandler.cs' 33 37
Show-CodeEvidence 'invoice-service/src/InvoiceService.Infrastructure/Persistence/InvoiceStore.cs' 40 46
Show-CodeEvidence 'invoice-service/src/InvoiceService.Infrastructure/Persistence/OutboxStore.cs' 10 39
Show-CodeEvidence 'invoice-service/src/InvoiceService.Application/Outbox/OutboxOutcomeWriter.cs' 21 47
Show-CodeEvidence 'invoice-service/src/InvoiceService.Infrastructure/Persistence/InvoiceStore.cs' 48 56
Write-Step 'Fatura status yazma yollarının kaynak taraması'
Push-Location $RepoRoot
try {
    # Ek araç gerektirmesin diye Select-String (rg kurulu olmayabilir); Migrations, bin ve obj taranmaz.
    $pattern = 'SetProperty\(i => i.Status|invoice.Status =|Status = InvoiceStatus|UPDATE invoices|SET status'
    Write-Host "KOMUT: Select-String -Pattern '$pattern' invoice-service/src/**/*.cs (Migrations, bin, obj hariç)"
    Get-ChildItem 'invoice-service/src' -Recurse -Filter '*.cs' |
        Where-Object { $_.FullName -notmatch '[\\/](Migrations|bin|obj)[\\/]' } |
        Select-String -Pattern $pattern |
        ForEach-Object { '{0}:{1}:{2}' -f (Resolve-Path -Relative $_.Path), $_.LineNumber, $_.Line.Trim() }
} finally { Pop-Location }
Write-Host 'YORUM - koddan çıkarılan 6 x 3 geçiş tablosu:'
Write-Host '  Durum            received                 approved               rejected'
Write-Host '  Bekliyor         Bekle                    Bekle                  Bekle'
Write-Host '  Gönderildi       İşleme Alındı            Onaylandı              Reddedildi'
Write-Host '  İşleme Alındı    Yok Say/İlerletmiyor      Onaylandı              Reddedildi'
Write-Host '  Onaylandı        Yok Say/Geri Götürüyor    Yok Say/Kesin Durumda   Yok Say/Kesin Durumda'
Write-Host '  Reddedildi       Yok Say/Geri Götürüyor    Yok Say/Kesin Durumda   Yok Say/Kesin Durumda'
Write-Host '  Başarısız        Bekle                    Bekle                  Bekle'
Show-CodeEvidence 'invoice-service/tests/InvoiceService.Domain.Tests/InvoiceTransitionsTests.cs' 7 51
Show-UnitEvidence 'InvoiceTransitionsTests'
Write-Host 'YORUM: Every_status_and_event_type_has_a_rule 18 birleşimin hepsini çağırır; Pending+rejected ve Failed+approved için ayrı beklenen sonuç assertion''ı yok, ortak Wait dalı kodda gösterildi.'

$ignoredCases = @(
    @{ Number=$approvedNumber; Type='invoice.rejected'; Reason='Kesin durumu değiştirmemeli'; Ignore='Kesin Durumda'; Invoice='Onaylandı' }
    @{ Number=$approvedNumber; Type='invoice.received'; Reason=''; Ignore='Geri Götürüyor'; Invoice='Onaylandı' }
    @{ Number=$rejectedNumber; Type='invoice.approved'; Reason=''; Ignore='Kesin Durumda'; Invoice='Reddedildi' }
    @{ Number=$processingNumber; Type='invoice.received'; Reason=''; Ignore='İlerletmiyor'; Invoice='İşleme Alındı' }
)
foreach ($case in $ignoredCases) {
    $ev = New-ProofEvent $case.Number $case.Type $case.Reason
    $r = Send-ProofEvent $ev
    Check 'geçerli imzalı haber HTTP 200' "$($ev.Id): $($r.Status)" ($r.Status -eq 200)
    Check-Event $ev 'Yok Sayıldı' $case.Ignore
    $state = [string]@(Get-ServiceRows "SELECT status FROM invoices WHERE invoice_number='$($case.Number)';")[0]
    Check "kesin/ilerlemiş fatura aynı kalıyor: $($case.Invoice)" $state ($state -eq $case.Invoice)
}
$direct = New-ProofEvent $directNumber 'invoice.approved'
$r = Send-ProofEvent $direct
Check 'Gönderildi -> doğrudan karar HTTP 200' "$($r.Status)" ($r.Status -eq 200)
Check-Event $direct 'İşlendi'
$directState = [string]@(Get-ServiceRows "SELECT status FROM invoices WHERE invoice_number='$directNumber';")[0]
Check 'doğrudan karar faturayı Onaylandı yapıyor' $directState ($directState -eq 'Onaylandı')
foreach ($n in @($approvedNumber, $rejectedNumber, $processingNumber)) {
    $snapshotSql = "SELECT status,erp_reference,coalesce(reject_reason,''),send_attempt_count,updated_at FROM invoices WHERE invoice_number='$n';"
    $before = [string]@(Get-ServiceRows $snapshotSql)[0]
    Write-Host "HTTP POST $ServiceUrl/api/v1/invoices/$n/resend"
    $r = Send-ServiceResend $n
    Write-Host "  Gelen HTTP $($r.HttpStatus): $($r.Body)"
    $after = [string]@(Get-ServiceRows $snapshotSql)[0]
    Check "resend $($n): 409 ve fatura değişmiyor" "$($r.HttpStatus); $before -> $after" ($r.HttpStatus -eq 409 -and $before -eq $after) $snapshotSql
}
Show-ServiceQuery "SELECT i.invoice_number,i.status,o.status AS outbox,o.claim_token FROM invoices i JOIN erp_outbox o USING(invoice_number) WHERE i.invoice_number IN ($(InList $numbers)) ORDER BY 1;"
Check-Zero 'bütün tabloda ileri fatura + Bekliyor outbox' "SELECT count(*) FROM invoices i JOIN erp_outbox o USING(invoice_number) WHERE i.status IN ('İşleme Alındı','Onaylandı','Reddedildi') AND o.status='Bekliyor';"
Check-Zero 'bütün tabloda işlenmiş en ileri haberinin gerisinde duran fatura' @"
SELECT count(*) FROM invoices i WHERE
(CASE i.status WHEN 'Onaylandı' THEN 3 WHEN 'Reddedildi' THEN 3 WHEN 'İşleme Alındı' THEN 2 WHEN 'Gönderildi' THEN 1 ELSE 0 END) <
(SELECT coalesce(max(CASE e.event_type WHEN 'invoice.received' THEN 2 ELSE 3 END),0) FROM erp_webhook_events e WHERE e.invoice_number=i.invoice_number AND e.status='İşlendi');
"@
Write-Step 'Bütün eldeki servis loglarında invoiceStatus=A->B kontrolü'
$primaryLog = @(Get-ServiceLog)
$primaryPath = Join-Path $OutputDir "gun4-ek-fatura-servisi-$stamp-service.log"
$primaryLog | Set-Content -LiteralPath $primaryPath -Encoding UTF8
$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
Push-Location $RepoRoot
try { $secondaryLog = @(& docker compose logs invoice-service-2 --no-log-prefix 2>$null) }
finally { Pop-Location; $ErrorActionPreference = $previous }
$secondaryPath = Join-Path $OutputDir "gun4-ek-fatura-servisi-$stamp-service2.log"
$secondaryLog | Set-Content -LiteralPath $secondaryPath -Encoding UTF8
$rank = @{ 'Bekliyor'=0; 'Başarısız'=0; 'Gönderildi'=1; 'İşleme Alındı'=2; 'Onaylandı'=3; 'Reddedildi'=3 }
$checked = 0; $backward = @()
foreach ($line in @($primaryLog) + @($secondaryLog)) {
    if ($line -notmatch 'invoiceStatus=(.+?)->(.+?) ignoreReason=') { continue }
    $a = $Matches[1]; $b = $Matches[2]; $checked++
    if ($rank[$b] -lt $rank[$a] -or ($rank[$a] -eq 3 -and $a -ne $b)) { $backward += $line }
}
foreach ($line in $backward) { Write-Host $line -ForegroundColor Red }
Write-Host "LOG KAYNAĞI: $primaryPath + $secondaryPath; $checked geçiş, $($backward.Count) geri"
Check 'bütün eldeki invoiceStatus loglarında geri gidiş 0' "$checked geçiş / geri $($backward.Count)" ($checked -gt 0 -and $backward.Count -eq 0)
Write-Host 'DOĞRULANMADI: container yeniden oluşturulmasıyla kaybolmuş eski loglar bu taramada yok; saklanan iki logun bütün satırları tarandı.'
Show-ServiceQuery "SELECT tgname,pg_get_triggerdef(oid) FROM pg_trigger WHERE tgrelid='invoices'::regclass AND NOT tgisinternal;"
Write-Host 'YORUM: ileri zinciri Gönderildi sonrasındaki iş akışına uygulamak ve Başarısız -> Bekliyor resend yolunu korumak önerilir; bütün yaşam döngüsüne katı bir sıralama istenirse ayrı bir yeniden gönderim modeli gerekir.'
Write-Host 'YORUM: durum geçişi trigger''ı yok. Yalnız uygulama yazıyorsa mevcut kilit/transaction kuralları yeterli; dış yazarlar olacaksa trigger veya sınırlı DB yazma yetkileri seçenekleri değerlendirilmelidir.'

$section = 'B3'
Write-Title 'B3) reject_reason'
$currentSource = 'InvoiceService.Domain/Invoices/Invoice.cs:23; InvoiceService.Infrastructure/Persistence/InvoiceDbContext.cs:39; InvoiceService.Infrastructure/Persistence/InvoiceStore.cs:58-62; InvoiceService.Application/Webhooks/InvoiceEventApplier.cs:25-26; InvoiceService.Application/Webhooks/ErpWebhookRequest.cs:36-37; InvoiceService.Api/Invoices/InvoiceResponse.cs:5-23'
Show-CodeEvidence 'invoice-service/src/InvoiceService.Api/Invoices/InvoiceResponse.cs' 5 23
Show-CodeEvidence 'invoice-service/src/InvoiceService.Application/Webhooks/ErpWebhookRequest.cs' 33 38
Show-ServiceQuery "SELECT column_name,data_type,is_nullable FROM information_schema.columns WHERE table_schema='public' AND table_name='invoices' AND column_name='reject_reason';"
$column = [string]@(Get-ServiceRows "SELECT data_type || '|' || is_nullable FROM information_schema.columns WHERE table_schema='public' AND table_name='invoices' AND column_name='reject_reason';")[0]
Check 'reject_reason text ve nullable' $column ($column -eq 'text|YES')
Check-Zero 'bütün tabloda Reddedildi ve boş reject_reason' "SELECT count(*) FROM invoices WHERE status='Reddedildi' AND (reject_reason IS NULL OR btrim(reject_reason)='');"
Check-Zero 'bütün tabloda Reddedildi dışında dolu reject_reason' "SELECT count(*) FROM invoices WHERE status<>'Reddedildi' AND reject_reason IS NOT NULL;"
Check-Zero 'bütün Reddedildi faturaların reason''ı işlenmiş red haberiyle birebir aynı' @"
SELECT count(*) FROM invoices i WHERE i.status='Reddedildi' AND NOT EXISTS
(SELECT 1 FROM erp_webhook_events e WHERE e.invoice_number=i.invoice_number AND e.event_type='invoice.rejected' AND e.status='İşlendi' AND e.payload::jsonb->>'reason'=i.reject_reason);
"@
$detail = Get-ProofInvoice $rejectedNumber
Check 'GET detay rejectReason içeriyor ve gelen reason ile aynı' "$($detail.Http) / $($detail.Invoice.rejectReason)" ($detail.Http -eq 200 -and $detail.Invoice.rejectReason -eq 'Kanıt: vergi numarası geçersiz')
$noReason = New-ProofEvent $approvedNumber 'invoice.rejected'
$r = Send-ProofEvent $noReason
$stored = Count-Service "SELECT count(*) FROM erp_webhook_events WHERE event_id='$($noReason.Id)';"
Check 'reason yok: geçerli imzaya rağmen HTTP 400 ve 0 kayıt' "$($r.Status) / $stored" ($r.Status -eq 400 -and $stored -eq 0)
Show-UnitEvidence 'WebhookRequestTests'

$section = 'B4'
Write-Title 'B4) erp_webhook_events: şema, ilk varış, işleme ve ham gövde'
$currentSource = 'InvoiceService.Domain/Webhooks/ErpWebhookEvent.cs:1-49; InvoiceService.Infrastructure/Persistence/InvoiceDbContext.cs:72-105; InvoiceService.Application/Webhooks/WebhookEventProcessor.cs:20-56,62-76; InvoiceService.Infrastructure/Persistence/WebhookEventStore.cs:20-44; InvoiceService.Api/Webhooks/WebhookEndpoints.cs:34-92; ilgili iki migration'
Show-CodeEvidence 'invoice-service/src/InvoiceService.Domain/Webhooks/ErpWebhookEvent.cs' 1 49
Show-CodeEvidence 'invoice-service/src/InvoiceService.Infrastructure/Persistence/InvoiceDbContext.cs' 72 105
Show-CodeEvidence 'invoice-service/src/InvoiceService.Application/Webhooks/WebhookEventProcessor.cs' 20 56
Show-CodeEvidence 'invoice-service/src/InvoiceService.Infrastructure/Persistence/WebhookEventStore.cs' 20 28
Show-ServiceQuery "SELECT ordinal_position,column_name,data_type,character_maximum_length,is_nullable,column_default FROM information_schema.columns WHERE table_schema='public' AND table_name='erp_webhook_events' ORDER BY ordinal_position;"
Show-ServiceQuery "SELECT conname,contype,convalidated,pg_get_constraintdef(oid) AS tanim FROM pg_constraint WHERE conrelid='erp_webhook_events'::regclass ORDER BY conname;"
$columns = @(Get-ServiceRows "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='erp_webhook_events' ORDER BY ordinal_position;")
$expectedColumns = @('event_id','event_type','invoice_number','erp_reference','occurred_at','received_at','processed_at','status','payload','delivery_count','ignore_reason')
Check 'görevin 9 kolonu ve gerekçeli 2 ek kolon' ($columns -join ', ') ((($columns | Sort-Object) -join '|') -eq (($expectedColumns | Sort-Object) -join '|'))
$pk = [string]@(Get-ServiceRows "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid='erp_webhook_events'::regclass AND contype='p';")[0]
Check 'event_id tekil primary key' $pk ($pk -eq 'PRIMARY KEY (event_id)')
Check-Zero 'bütün tabloda event_id tekrar satırı' "SELECT count(*)-count(DISTINCT event_id) FROM erp_webhook_events;"
Check-Zero 'bütün tabloda gövdeyle farklı event_id/type/number/reference veya occurred_at (>1 us)' @"
SELECT count(*) FROM erp_webhook_events WHERE
event_id IS DISTINCT FROM payload::jsonb->>'event_id' OR event_type IS DISTINCT FROM payload::jsonb->>'event_type' OR
invoice_number IS DISTINCT FROM payload::jsonb->>'invoice_number' OR erp_reference IS DISTINCT FROM payload::jsonb->>'erp_reference' OR
payload::jsonb->>'occurred_at' IS NULL OR abs(extract(epoch FROM occurred_at-(payload::jsonb->>'occurred_at')::timestamptz)) > 0.000001;
"@
Show-ServiceQuery "SELECT status,count(*) AS satir,min(delivery_count),max(delivery_count) FROM erp_webhook_events GROUP BY status ORDER BY status;"
Check-Zero 'bütün tabloda üç değer dışındaki haber status''u' "SELECT count(*) FROM erp_webhook_events WHERE status NOT IN ('İşlendi','Bekliyor','Yok Sayıldı');"
Check-Zero 'bütün tabloda processed_at doluluğu kurala aykırı' "SELECT count(*) FROM erp_webhook_events WHERE (status IN ('Bekliyor','Yok Sayıldı') AND processed_at IS NOT NULL) OR (status='İşlendi' AND processed_at IS NULL);"

Write-Step 'Canlı tekrar: received_at ve ham gövde aynı, delivery_count artıyor'
$repeat = New-ProofEvent $processingNumber 'invoice.received'
$repeat.Body = '  ' + $repeat.Body + '  '
$r1 = Send-ProofEvent $repeat
$first = [string]@(Get-ServiceRows "SELECT received_at || '|' || coalesce(processed_at::text, '-') || '|' || delivery_count FROM erp_webhook_events WHERE event_id='$($repeat.Id)';")[0]
Start-Sleep -Seconds 1
$r2 = Send-ProofEvent $repeat
$second = [string]@(Get-ServiceRows "SELECT received_at || '|' || coalesce(processed_at::text, '-') || '|' || delivery_count FROM erp_webhook_events WHERE event_id='$($repeat.Id)';")[0]
Show-ServiceQuery "SELECT event_id,received_at,processed_at,delivery_count,octet_length(payload) AS govde_bayti FROM erp_webhook_events WHERE event_id='$($repeat.Id)';"
$parts1 = $first -split '\|'; $parts2 = $second -split '\|'
Check 'iki geliş 200; received_at/processed_at aynı; delivery_count 1 -> 2' "$first -> $second" ($r1.Status -eq 200 -and $r2.Status -eq 200 -and $parts1[0] -eq $parts2[0] -and $parts1[1] -eq $parts2[1] -and $parts1[2] -eq '1' -and $parts2[2] -eq '2')
$storedBody = [string]@(Get-ServiceRows "SELECT replace(encode(convert_to(payload,'UTF8'),'base64'),chr(10),'') FROM erp_webhook_events WHERE event_id='$($repeat.Id)';")[0]
$sentBody = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($repeat.Body))
Check 'elle gönderilen boşluklu ham gövde bayt bayt aynı' "gönderilen $($sentBody.Length) base64 karakteri / eşit=$($storedBody -ceq $sentBody)" ($storedBody -ceq $sentBody)

Write-Step 'Bütün ortak event_id''lerde simülatör ve servis payload bayt karşılaştırması'
$serviceSql = "SELECT event_id,replace(encode(convert_to(payload,'UTF8'),'base64'),chr(10),'') FROM erp_webhook_events ORDER BY event_id;"
$erpSql = "SELECT event_id,replace(encode(convert_to(payload,'UTF8'),'base64'),chr(10),'') FROM webhook_deliveries ORDER BY id;"
Write-Host "KOMUT: docker compose exec -T invoice-db psql -U invoice -d invoice_service -tA -F '|' -c $serviceSql"
Write-Host "KOMUT: docker compose exec -T erp-db psql -U erp -d erp_simulator -tA -F '|' -c $erpSql"
$servicePayloads = @{}
foreach ($line in @(Get-ServiceRows $serviceSql)) { $p = $line -split '\|',2; $servicePayloads[$p[0]] = $p[1] }
$shared = @{}; $compared = 0; $different = @()
foreach ($line in @(Get-ErpRows $erpSql)) {
    $p = $line -split '\|',2
    if (-not $servicePayloads.ContainsKey($p[0])) { continue }
    $shared[$p[0]] = $true; $compared++
    if ($servicePayloads[$p[0]] -cne $p[1]) { $different += $p[0] }
}
foreach ($id in $different) { Write-Host "  FARKLI: $id" -ForegroundColor Red }
Check 'bütün ortak event_id''lerde ham payload farkı 0' "$($shared.Count) ortak kimlik, $compared simülatör satırı, $($different.Count) fark; sayılar yukarıdaki iki SQL'den" ($shared.Count -gt 0 -and $different.Count -eq 0)
Show-ErpQuery "SELECT kind,status,count(*) AS satir FROM webhook_deliveries GROUP BY kind,status ORDER BY kind,status;"

Write-Step 'Faturanın Gönderildi olmasından önce gelen haberin processed_at zamanı'
$settings = Get-SimSettings -Behavior 'LateResponse' -NoEvents
Restart-Simulator $settings
$earlyInvoice = New-ProofInvoice
$earlyNumber = $earlyInvoice.InvoiceNumber
$watch = [Diagnostics.Stopwatch]::StartNew()
do {
    $erpRecord = Get-SimulatorInvoice $earlyNumber
    if ($erpRecord.HttpStatus -eq 200 -and $erpRecord.RecordCount -gt 0) { break }
    if ($watch.Elapsed.TotalSeconds -gt 8) { throw 'Geç cevap faturasının ERP kaydı 8 sn içinde görülmedi.' }
    Start-Sleep -Milliseconds 100
} while ($true)
$early = New-ProofEvent $earlyNumber 'invoice.received' '' (@($erpRecord.References)[0])
$r = Send-ProofEvent $early
Check 'Gönderildi öncesi haber HTTP 200 / Bekliyor' "$($r.Status) / $($r.Body)" ($r.Status -eq 200 -and ($r.Body | ConvertFrom-Json).status -eq 'Bekliyor')
Check-Event $early 'Bekliyor'
Wait-QueueDrained $earlyNumber $earlyNumber 90 | Out-Null
Check-Event $early 'İşlendi'
$timeSql = "SELECT e.event_id,e.received_at,e.processed_at AS haber_islendi,o.processed_at AS gonderildi,extract(epoch FROM e.processed_at-o.processed_at)*1000 AS fark_ms FROM erp_webhook_events e JOIN erp_outbox o USING(invoice_number) WHERE e.event_id='$($early.Id)';"
Show-ServiceQuery $timeSql
$equal = Count-Service "SELECT count(*) FROM erp_webhook_events e JOIN erp_outbox o USING(invoice_number) WHERE e.event_id='$($early.Id)' AND e.processed_at=o.processed_at;"
Check 'erken haberin processed_at''i outbox.processed_at ile birebir aynı' "$equal / 1; fark_ms yukarıdaki SQL'de" ($equal -eq 1) $timeSql
Write-Host 'YORUM: outbox, bekleyen haberleri faturayı Gönderildi yaptığı transaction''da ve aynı zamanla işler (OutboxProcessor ApplyWaitingAsync(..., now, ...)); bu yüzden iki zaman birebir aynı olmalı.'
Check-Zero 'erken örnek dahil bütün tabloda processed_at doluluğu' "SELECT count(*) FROM erp_webhook_events WHERE (status IN ('Bekliyor','Yok Sayıldı') AND processed_at IS NOT NULL) OR (status='İşlendi' AND processed_at IS NULL);"
Restart-Simulator (Get-SimSettings -NoEvents)

Write-Step '401 / 400 / 413: HTTP ve 0 kayıt kanıtı'
$since = [datetime]::UtcNow.AddSeconds(-1)
foreach ($kind in @('yanlış imza','eksik başlık','eski damga','bozuk JSON','büyük gövde')) {
    $ev = New-ProofEvent $approvedNumber 'invoice.approved'
    $expected = 401
    switch ($kind) {
        'yanlış imza' { $r = Send-ProofEvent $ev -BadSignature }
        'eksik başlık' { $r = Send-ProofEvent $ev -NoHeaders }
        'eski damga' { $r = Send-ProofEvent $ev -AgeSeconds 600 }
        'bozuk JSON' { $expected = 400; $ev.Body = '{"event_id":"' + $ev.Id + '","event_type":'; $r = Send-ProofEvent $ev }
        'büyük gövde' { $expected = 413; $ev.Body = $ev.Body.Substring(0,$ev.Body.Length-1) + ',"padding":"' + ('x' * 65536) + '"}'; $r = Send-ProofEvent $ev }
    }
    $sql = "SELECT count(*) FROM erp_webhook_events WHERE event_id='$($ev.Id)';"
    Show-ServiceQuery $sql
    $count = Count-Service $sql
    Check "$kind : HTTP $expected ve 0 kayıt" "$($r.Status) / $count" ($r.Status -eq $expected -and $count -eq 0) $sql
}
$rejectLog = @(Get-WebhookLog $since | Where-Object { $_ -match 'http=(401|400|413)' })
foreach ($line in $rejectLog) { Write-Host $line -ForegroundColor DarkGray }
$codes = @{}
foreach ($line in $rejectLog) { if ($line -match 'http=(401|400|413)') { $codes[$Matches[1]] = [int]$codes[$Matches[1]] + 1 } }
Check 'servis logunda canlı reddetmeler: 401=3, 400=1, 413=1' "$([int]$codes['401']) / $([int]$codes['400']) / $([int]$codes['413'])" ([int]$codes['401'] -eq 3 -and [int]$codes['400'] -eq 1 -and [int]$codes['413'] -eq 1)
Show-UnitEvidence 'WebhookSignatureTests'
Write-Host 'YORUM: 401 için kaydetmeme görevde açık. 400/413 için uygulama ek kabul sınırı var: öneri, yalnız kabul edilmiş haberleri iş tablosuna yazıp reddedilmiş teslim denemelerini ayrı log/audit kanalında tutmak; alternatif, ayrı bir rejected-deliveries tablosudur.'
Write-Host 'Kolon gerekçesi önerisi: delivery_count, tekil haber satırını çoğaltmadan tekrar gelişlerin sayısını ve yeniden işlenmediğini kanıtlamak için eklenmiştir.'
Write-Host 'Kolon gerekçesi önerisi: ignore_reason, Yok Sayıldı haberlerin hangi iş kuralı nedeniyle uygulanmadığını açıklamak ve neden bazında raporlamak için eklenmiştir.'

$proofIds = @($proofEvents.Keys | Sort-Object)
Write-Step 'Bu scriptin ürettiği kabul edilmiş haberler'
Show-ServiceQuery "SELECT event_id,event_type,invoice_number,status,ignore_reason,delivery_count FROM erp_webhook_events WHERE event_id IN ($(InList $proofIds)) ORDER BY invoice_number,received_at;"
$evidence | Export-Csv -LiteralPath $evidenceFile -Encoding UTF8 -NoTypeInformation
Cleanup
Write-Title 'B1-B4 sonuç özeti'
foreach ($group in @($evidence | Group-Object Section | Sort-Object Name)) {
    $failed = @($group.Group | Where-Object { -not $_.Passed }).Count
    Write-Host "  $($group.Name): $($group.Count) kontrol, kalan $failed; $(if ($failed) { 'KALDI' } else { 'GEÇTİ' })"
}
Write-Host "Kanıt CSV: $evidenceFile"
Write-Result $allPassed 'B1-B4 tamamlandı; kalan varsa uygulama değiştirilmedi, kanıt ve yorum raporlanır'
Stop-Transcript | Out-Null
if (-not $allPassed) { exit 1 }

