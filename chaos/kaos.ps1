# Kaos otomasyonu: yük altında bugüne kadar denenen sekiz arızayı rastgele sırayla ve zamanla oluşturur, sistemin durulmasını
# bekler ve garantileri birlikte kontrol eder. Sonucun ilk satırı YEŞİL, KIRMIZI ya da DURULMADI'dır.
#   .\chaos\kaos.ps1                 yeni bir sıra (seed rastgele seçilir ve sonuçta yazılır)
#   .\chaos\kaos.ps1 -Seed 4711      aynı seed: aynı plan (arızalar, sıra, planlanan başlangıç ve süreler)
#   .\chaos\kaos.ps1 -Seed 4711 -PlanOnly   yalnız planı gösterir, hiçbir şey çalıştırmaz
# Her koşu boş veritabanlarıyla başlar (kendi volume'leri) ve çalışan compose kurulumunun yerine geçer. Çıktılar
# chaos\results\<zaman>-seed<seed>\ altında (sonuc.txt, plan.json, arizalar.csv, k6.txt, simulator.log, yedek\). Okunuşu: README.
param(
    [int]$Seed = 0,
    # Yük: k6, saniyede Rate fatura, Duration boyunca, iki kopyaya sırayla.
    [int]$Rate = 20,
    [string]$Duration = '10m',
    # Bir arızanın en kısa ve en uzun süresi, saniye. 10 deneme ~5 dakikada biter; daha uzun kesinti faturayı meşru biçimde
    # Başarısız yapar.
    [int]$MinFaultSeconds = 20,
    [int]$MaxFaultSeconds = 90,
    # Aynı anda açık olabilecek en çok arıza.
    [int]$MaxOverlap = 3,
    # Son arıza bittikten sonra sistemin durulması için beklenen en uzun süre.
    [int]$SettleMinutes = 45,
    [switch]$PlanOnly
)
. "$PSScriptRoot\_kaos-yardimci.ps1"

$LoadSeconds = [int]$Duration.TrimEnd('m', 's') * $(if ($Duration.EndsWith('m')) { 60 } else { 1 })
# Arızalar yükün ilk ve son bu kadar saniyesinde olmaz: yük başlamış ve arızalar bittikten sonra da sürüyor olsun.
$EdgeSeconds = 30
# Yedek aralığı 5 dakika (docker-compose.yml): veritabanı kaybı yükün içinde alınmış bir yedekten sonra olsun.
$DatabaseLossEarliest = 330
# Veritabanı kaybının planda kapladığı süre (geri dönüş betiği yük altında ~1-2 dk); gerçek bitişi betiğin bitişidir.
$DatabaseLossSeconds = 120

if ($Seed -eq 0) { $Seed = Get-Random -Minimum 1 -Maximum 1000000 }

# ---------------------------------------------------------------------------------------------------------------------------
# Plan: aynı seed aynı planı verir. Sıra rastgele bir permütasyon; her arızanın başlangıcı bir öncekinden 5-40 sn sonra,
# süresi MinFaultSeconds-MaxFaultSeconds arası. Aynı container'a dokunan iki arıza üst üste gelmez (biri ötekini bozar), aynı
# anda en çok MaxOverlap arıza açık olur, hepsi yük penceresinde biter. Sığmayan çekiliş atılır, aynı Random'dan yenisi çekilir.
# ---------------------------------------------------------------------------------------------------------------------------
$Catalog = @(
    @{ Key = 'erp-cokmesi'; Ad = 'ERP çökmesi'; Groups = @('erp') }
    @{ Key = 'erp-yavaslamasi'; Ad = 'ERP yavaşlaması'; Groups = @('erp') }
    @{ Key = 'ag-kopmasi'; Ad = 'Ağın kopması (ERP)'; Groups = @('erp') }
    @{ Key = 'worker-olmesi'; Ad = "Worker'ın ölmesi (kopya 1)"; Groups = @('servis-1') }
    @{ Key = 'kopya-olmesi'; Ad = 'Servis kopyasının ölmesi (kopya 2)'; Groups = @('servis-2') }
    @{ Key = 'haber-kaybi'; Ad = 'Haberlerin kaybolması'; Groups = @('erp') }
    @{ Key = 'veritabani-kaybi'; Ad = 'Veritabanı kaybı'; Groups = @('servis-1', 'servis-2', 'veritabani') }
    @{ Key = 'surum-gecisi'; Ad = 'ERP sürüm geçişi'; Groups = @('surum') }
)

function New-Plan([int]$PlanSeed) {
    $rng = [Random]::new($PlanSeed)
    for ($try = 0; $try -lt 10000; $try++) {
        $order = [Collections.Generic.List[object]]::new()
        foreach ($c in $Catalog) { $order.Add($c) }
        for ($i = $order.Count - 1; $i -gt 0; $i--) { $j = $rng.Next($i + 1); $tmp = $order[$i]; $order[$i] = $order[$j]; $order[$j] = $tmp }
        $percent = @(10, 50, 100)[$rng.Next(3)]
        $v1Closed = $rng.Next(2) -eq 1
        $t = $EdgeSeconds + $rng.Next(0, 31)
        $faults = [Collections.Generic.List[object]]::new()
        $fits = $true
        foreach ($c in $order) {
            $groups = @($c.Groups)
            if ($c.Key -eq 'surum-gecisi' -and $v1Closed) { $groups += 'erp' }
            $length = if ($c.Key -eq 'veritabani-kaybi') { $DatabaseLossSeconds } else { $rng.Next($MinFaultSeconds, $MaxFaultSeconds + 1) }
            $start = if ($c.Key -eq 'veritabani-kaybi') { [Math]::Max($t, $DatabaseLossEarliest) } else { $t }
            while ($true) {
                $active = @($faults | Where-Object { $_.Start -le $start -and $start -lt $_.Start + $_.Seconds })
                $clash = @($faults | Where-Object { $start -lt $_.Start + $_.Seconds -and $_.Start -lt $start + $length -and
                    @($_.Groups | Where-Object { $groups -contains $_ }).Count -gt 0 })
                if ($active.Count -lt $MaxOverlap -and $clash.Count -eq 0) { break }
                $start += 5
            }
            if ($start + $length -gt $LoadSeconds - $EdgeSeconds) { $fits = $false; break }
            $fault = [pscustomobject]@{ Order = $faults.Count + 1; Key = $c.Key; Ad = $c.Ad; Groups = $groups; Start = $start; Seconds = $length
                Percent = $null; V1Closed = $false }
            if ($c.Key -eq 'surum-gecisi') {
                $fault.Percent = $percent; $fault.V1Closed = $v1Closed
                $fault.Ad = "ERP sürüm geçişi (yüzde $percent$(if ($v1Closed) { ', v1 kapalı' }), sonunda yüzde 0)"
            }
            $faults.Add($fault)
            $t = $start + $rng.Next(5, 41)
        }
        if ($fits) { return , $faults }
    }
    throw "Bu sınırlarla plan kurulamadı (Duration $Duration, arıza $MinFaultSeconds-$MaxFaultSeconds sn)."
}

function Format-Offset([double]$Seconds) { '{0:00}:{1:00}' -f [Math]::Floor($Seconds / 60), [Math]::Floor($Seconds % 60) }

$plan = New-Plan $Seed
Write-Host "Seed $Seed, yük $Rate/sn x $Duration; plan (yük başlangıcından itibaren):"
foreach ($f in $plan) { Write-Host ("  {0}. {1}-{2}  {3}" -f $f.Order, (Format-Offset $f.Start), (Format-Offset ($f.Start + $f.Seconds)), $f.Ad) }
if ($PlanOnly) { return }

# ---------------------------------------------------------------------------------------------------------------------------
# Kurulum
# ---------------------------------------------------------------------------------------------------------------------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$RunName = "$stamp-seed$Seed"
$RunDir = Join-Path $PSScriptRoot "results\$RunName"
New-Item -ItemType Directory -Force (Join-Path $RunDir 'yedek') | Out-Null
$script:SimulatorLogFile = Join-Path $RunDir 'simulator.log'
$plan | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $RunDir 'plan.json') -Encoding UTF8
$RunId = "KAOS-$Seed-$($stamp -replace '-', 'T')"
$Vol = ($stamp -replace '-', '')
$env:KAOS_VOL = $Vol
$env:COMPOSE_FILE = (Join-Path $RepoRoot 'docker-compose.yml') + ';' + (Join-Path $PSScriptRoot 'compose.kaos.yml')
$env:COMPOSE_PROFILES = 'iki-kopya'
$env:INVOICE_BACKUP_DIR = "./chaos/results/$RunName/yedek"
Remove-Item Env:BACKUP_INTERVAL_SECONDS -ErrorAction SilentlyContinue
foreach ($key in $SimulatorKeys) { Remove-Item "Env:$key" -ErrorAction SilentlyContinue }

$startedAt = Get-Date
Write-Host "Koşu ${RunName}: kurulum (boş veritabanları, iki kopya)..."
[void](Invoke-Compose @('down', '--remove-orphans'))
[void](Invoke-Compose @('up', '-d', '--build'))
Wait-For { (Test-Up "$KeycloakUrl/realms/fatura/.well-known/openid-configuration") -and (Test-Up "$ServiceUrl/health") -and
    (Test-Up 'http://127.0.0.1:5091/health') -and (Test-Up "$SimulatorUrl/health") } 300 'Kurulumun açılması'
[void](Get-OperatorToken)

# ---------------------------------------------------------------------------------------------------------------------------
# Yük ve arızalar
# ---------------------------------------------------------------------------------------------------------------------------
$k6Job = Start-Job -ScriptBlock { param($root, $composeFile, $vol, $backupDir, $rate, $duration, $run)
    Set-Location $root
    $env:COMPOSE_FILE = $composeFile; $env:KAOS_VOL = $vol; $env:INVOICE_BACKUP_DIR = $backupDir; $env:COMPOSE_PROFILES = 'iki-kopya'
    $env:RATE = $rate; $env:DURATION = $duration; $env:RUN_ID = $run; $env:LOG_ACCEPTED = 'true'
    $env:BASE_URLS = 'http://invoice-service:8080,http://invoice-service-2:8080'
    docker compose --profile yuk-testi run --rm k6 2>&1 | ForEach-Object { "$_" }
} -ArgumentList $RepoRoot, $env:COMPOSE_FILE, $Vol, $env:INVOICE_BACKUP_DIR, "$Rate", $Duration, $RunId
$LoadStart = [DateTimeOffset]::UtcNow
Write-Host "Yük başladı ($RunId)."

# Gerçekleşen arızalar: başlangıç ve bitiş, yük başlangıcından itibaren saniye.
$executed = [Collections.Generic.List[object]]::new()
$queue = [Collections.Generic.List[object]]::new()   # { At; Kind = start|end; Fault }
foreach ($f in $plan) { $queue.Add([pscustomobject]@{ At = [double]$f.Start; Kind = 'start'; Fault = $f }) }
$busyGroups = @{}   # grup -> arızanın sırası
$script:V2Percent = 0
$dbJob = $null; $dbFault = $null; $dbRecord = $null
$cancelCodes = @{}
$lastCancel = [datetime]::MinValue
function Get-Elapsed { ([DateTimeOffset]::UtcNow - $LoadStart).TotalSeconds }

# Yük sırasında iptal istekleri: her 5 sn'de bu koşunun rastgele 3 faturası (kuyrukta ya da ERP'ye ulaşmış, iptali olmayan).
function Request-Cancels {
    if (((Get-Date) - $script:lastCancel).TotalSeconds -lt 5) { return }
    $script:lastCancel = Get-Date
    $numbers = Get-Rows (Invoke-InvoiceSql ("SELECT i.invoice_number FROM invoices i WHERE i.customer_code = '$RunId' AND i.status IN " +
        "('Bekliyor', 'Gönderildi', 'İşleme Alındı', 'Onaylandı') AND NOT EXISTS (SELECT 1 FROM erp_outbox c WHERE " +
        "c.invoice_number = i.invoice_number AND c.kind = 'İptal') ORDER BY random() LIMIT 3"))
    foreach ($n in $numbers) {
        if ($n[0] -notmatch '^FTR-') { continue }
        $r = Send-Api POST "/api/v1/invoices/$($n[0])/cancel" (Get-OperatorToken)
        $script:cancelCodes["$($r.Status)"] = 1 + [int]$script:cancelCodes["$($r.Status)"]
    }
}

function Complete-DatabaseLoss {
    $lines = @(Receive-Job $script:dbJob -Wait -AutoRemoveJob)
    $lines | Set-Content (Join-Path $RunDir 'veritabani-kaybi.txt') -Encoding UTF8
    $deleted = ($lines | Where-Object { $_ -match '^SILINDI ' } | Select-Object -First 1) -replace '^SILINDI ', ''
    $backup = ($lines | Where-Object { $_ -match 'Kullanilan yedek: (invoice_\S+\.dump)' } | Select-Object -First 1)
    $script:DeletedAt = if ($deleted) { [DateTimeOffset]::Parse($deleted) } else { $null }
    $script:BackupAt = if ($backup -match 'invoice_(\d{8}T\d{6}Z)\.dump') {
        [DateTimeOffset]::ParseExact($Matches[1], "yyyyMMdd'T'HHmmss'Z'", [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal) } else { $null }
    $script:dbRecord.End = Get-Elapsed
    # Geri yükleme sürüm yüzdesini yedekteki değere döndürür: o anki değer yeniden yazılır.
    Wait-For { Test-Up "$ServiceUrl/health" } 180 'Servisin geri dönüşten sonra açılması'
    Set-V2Percent $script:V2Percent
    foreach ($g in $script:dbFault.Groups) { $script:busyGroups.Remove($g) }
    Write-Host ("  {0} Veritabanı kaybı bitti (yedek {1})" -f (Format-Offset (Get-Elapsed)), $(if ($script:BackupAt) { $script:BackupAt.ToLocalTime().ToString('HH:mm:ss') } else { 'yok' }))
    $script:dbJob = $null
}

$lastBeat = Get-Date
while ($queue.Count -gt 0 -or $dbJob) {
    # Dakikada bir durum satırı: koşu takılırsa nerede beklediği görünür.
    if (((Get-Date) - $lastBeat).TotalSeconds -ge 60) {
        $lastBeat = Get-Date
        $waiting = $queue | Sort-Object At | Select-Object -First 1
        Write-Host ("  {0} sürüyor; açık: {1}; sıradaki: {2}" -f (Format-Offset (Get-Elapsed)),
            (@($executed | Where-Object { $null -eq $_.End } | ForEach-Object { $_.Order }) -join ','),
            $(if ($waiting) { "$($waiting.Fault.Order). $($waiting.Kind) $(Format-Offset $waiting.At)" } else { 'veritabanı kaybının bitmesi' }))
    }
    if ($dbJob -and $dbJob.State -ne 'Running') { Complete-DatabaseLoss; continue }
    # Zamanı gelmiş bir bitiş önce işlenir: aynı container'ı bekleyen bir başlangıç, kendisinden biraz sonraya düşen bir bitişi
    # bekletmesin. Başlangıçlar plandaki sırayla, en erkeninden.
    $now = Get-Elapsed
    $next = $queue | Where-Object { $_.Kind -eq 'end' -and $_.At -le $now } | Sort-Object At | Select-Object -First 1
    if (-not $next) { $next = $queue | Where-Object { $_.Kind -eq 'start' } | Sort-Object At | Select-Object -First 1 }
    if (-not $next) { $next = $queue | Sort-Object At | Select-Object -First 1 }
    if (-not $next -or $now -lt $next.At) { Request-Cancels; Start-Sleep -Milliseconds 500; continue }
    $f = $next.Fault
    if ($next.Kind -eq 'start') {
        # Bir önceki arıza (örn. uzun süren geri dönüş) aynı container'ı hâlâ tutuyorsa onun bitmesi beklenir.
        if (@($f.Groups | Where-Object { $busyGroups.ContainsKey($_) }).Count -gt 0) { Request-Cancels; Start-Sleep -Milliseconds 500; continue }
        [void]$queue.Remove($next)
        foreach ($g in $f.Groups) { $busyGroups[$g] = $f.Order }
        $record = [pscustomobject]@{ Order = $f.Order; Key = $f.Key; Ad = $f.Ad; Start = (Get-Elapsed); End = $null }
        $executed.Add($record)
        Write-Host ("  {0} başladı: {1}. {2}" -f (Format-Offset $record.Start), $f.Order, $f.Ad)
        if ($f.Key -eq 'veritabani-kaybi') {
            # Yük sırasında alınmış bir yedek olmadan silinmez: geri dönüş betiği yedek bulamazsa veritabanı geri gelmez.
            Wait-For { @(Get-ChildItem (Join-Path $RunDir 'yedek') -Filter 'invoice_*.dump' | Where-Object {
                [DateTimeOffset]::ParseExact(($_.Name -replace '^invoice_|\.dump$', ''), "yyyyMMdd'T'HHmmss'Z'",
                    [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal) -gt $LoadStart }).Count -gt 0 } 360 'Yük sırasında yedek alınması'
            $dbFault = $f; $dbRecord = $record
            $dbJob = Start-Job -ScriptBlock $DatabaseLossJob -ArgumentList $RepoRoot, $env:COMPOSE_FILE, $Vol, $env:INVOICE_BACKUP_DIR, $Bash
        }
        else {
            Start-Fault $f
            $queue.Add([pscustomobject]@{ At = $record.Start + $f.Seconds; Kind = 'end'; Fault = $f })
        }
    }
    else {
        [void]$queue.Remove($next)
        Stop-Fault $f
        $record = $executed | Where-Object { $_.Order -eq $f.Order }
        $record.End = Get-Elapsed
        foreach ($g in $f.Groups) { $busyGroups.Remove($g) }
        Write-Host ("  {0} bitti: {1}. {2}" -f (Format-Offset $record.End), $f.Order, $f.Ad)
    }
}
$lastFaultEnd = $LoadStart.AddSeconds(($executed | Measure-Object End -Maximum).Maximum)
$executed | Select-Object Order, Key, Ad, @{ n = 'Start'; e = { [Math]::Round($_.Start, 1) } }, @{ n = 'End'; e = { [Math]::Round($_.End, 1) } } |
    Export-Csv (Join-Path $RunDir 'arizalar.csv') -NoTypeInformation -Encoding UTF8

while ($k6Job.State -eq 'Running') { Request-Cancels; Start-Sleep -Seconds 1 }
$k6Lines = @(Receive-Job $k6Job -Wait -AutoRemoveJob)
$k6Lines | Set-Content (Join-Path $RunDir 'k6.txt') -Encoding UTF8
$accepted = @{}
foreach ($line in $k6Lines) { if ($line -match 'ACCEPTED (FTR-\d+) (\S+Z)') { $accepted[$Matches[1]] = [DateTimeOffset]::Parse($Matches[2]) } }
Write-Host "Yük bitti: 202 alan $($accepted.Count) fatura."
# Hiç 202 okunamadıysa kayıp kontrolü boşa geçer ve sonuç yanlışlıkla YEŞİL çıkar: koşu geçersizdir.
if ($accepted.Count -eq 0) { throw "k6 çıktısında 202 satırı yok (chaos\results\$RunName\k6.txt); koşu geçersiz." }

# ---------------------------------------------------------------------------------------------------------------------------
# Durulma: outbox'ta bekleyen satır ve ERP'de gönderilmeyi bekleyen haber kalmaz. Son arızadan sonra SettleMinutes içinde.
# ---------------------------------------------------------------------------------------------------------------------------
function Wait-Settled([DateTimeOffset]$Deadline) {
    while ([DateTimeOffset]::UtcNow -lt $Deadline) {
        $pendingRows = Invoke-InvoiceSql "SELECT count(*) FROM erp_outbox WHERE status = 'Bekliyor'"
        $pendingEvents = Invoke-ErpSql "SELECT count(*) FROM webhook_deliveries WHERE status IN ('Pending', 'Waiting')"
        if ($pendingRows -eq '0' -and $pendingEvents -eq '0') { return $true }
        if (((Get-Date) - $script:lastBeat).TotalSeconds -ge 60) {
            $script:lastBeat = Get-Date
            Write-Host "  Durulma bekleniyor: outbox'ta Bekliyor $pendingRows, ERP'de bekleyen haber $pendingEvents"
        }
        Start-Sleep -Seconds 10
    }
    $false
}
$settleDeadline = $lastFaultEnd.AddMinutes($SettleMinutes)
$settled = Wait-Settled $settleDeadline
$settledAt = [DateTimeOffset]::UtcNow

# Mutabakat: elle başlatılır, bitmesi beklenir; zamanlanmış çalışma kilidi tutuyorsa (409) sonra yeniden denenir.
function Invoke-Reconciliation {
    for ($i = 0; $i -lt 60; $i++) {
        $r = Send-Api POST '/api/v1/reconciliation-runs' (Get-OperatorToken)
        if ($r.Status -eq 202) { break }
        Start-Sleep -Seconds 10
    }
    if ($r.Status -ne 202) { throw "Mutabakat başlatılamadı: HTTP $($r.Status) $($r.Body)" }
    do {
        Start-Sleep -Seconds 3
        $run = (Send-Api GET "/api/v1/reconciliation-runs/$($r.Json.id)" (Get-OperatorToken)).Json.run
    } while ($null -eq $run -or $run.status -eq 'Çalışıyor')
    $run
}

# Veritabanı kaybında yedekten sonra 202 alıp kaybolan faturalar (yedek aralığı kaybı): ayrı sayılır, garanti bozulması değil.
$service = @{}
foreach ($row in (Get-Rows (Invoke-InvoiceSql "SELECT invoice_number, status, erp_reference, $(Iso 'updated_at') FROM invoices WHERE customer_code = '$RunId'" -Strict))) {
    $service[$row[0]] = $row
}
$gapLost = [Collections.Generic.List[string]]::new()
$violations = [Collections.Generic.List[object]]::new()   # { Guarantee; Invoice; At; Detail }
function Add-Violation([string]$Guarantee, [string]$Invoice, $At, [string]$Detail) {
    $violations.Add([pscustomobject]@{ Guarantee = $Guarantee; Invoice = $Invoice; At = $At; Detail = $Detail })
}
$G1 = '202 almış hiçbir fatura kaybolmamış'; $G2 = "ERP'de çift fatura yok"; $G3 = "Hiçbir iptal faturasından önce ERP'ye ulaşmamış"
$G4 = 'Takılı fatura ya da iptal kalmamış'; $G5 = 'Son mutabakat temiz'

foreach ($n in $accepted.Keys) {
    if ($service.ContainsKey($n)) { continue }
    $at = $accepted[$n]
    if ($BackupAt -and $DeletedAt -and $at -ge $BackupAt.AddSeconds(-2) -and $at -le $DeletedAt.AddSeconds(10)) { $gapLost.Add($n) }
    else { Add-Violation $G1 $n $at '202 aldı, serviste yok' }
}
$run1 = $null; $run2 = $null
if ($settled) {
    # Takılı sayılma süresi (StuckAfterMinutes 2) dolsun; ilk mutabakat kaybolan kararları düzeltir.
    Start-Sleep -Seconds 150
    $run1 = Invoke-Reconciliation
    # İlk mutabakatın yeniden kuyruğa aldığı iptaller ve onların haberleri bitsin; yoksa kontrol yarım işi takılı sayar.
    if (-not (Wait-Settled $settleDeadline)) { $settled = $false }
    if ($settled) { foreach ($row in (Get-Rows (Invoke-InvoiceSql ("SELECT invoice_number, status, $(Iso 'updated_at') " +
        "FROM invoices WHERE status IN ('Gönderildi', 'İşleme Alındı')") -Strict))) {
        Add-Violation $G4 $row[0] ([DateTimeOffset]::Parse($row[2])) "mutabakattan sonra hâlâ $($row[1])"
    }
    foreach ($row in (Get-Rows (Invoke-InvoiceSql ("SELECT invoice_number, kind, $(Iso 'created_at') " +
        "FROM erp_outbox WHERE status = 'Bekliyor'") -Strict))) {
        Add-Violation $G4 $row[0] ([DateTimeOffset]::Parse($row[2])) "$($row[1]) satırı hâlâ Bekliyor"
    } }
    $run2 = if ($settled) { Invoke-Reconciliation } else { $null }
    $gapSet = @{}; foreach ($n in $gapLost) { $gapSet[$n] = $true }
    if ($run2) { foreach ($row in (Get-Rows (Invoke-InvoiceSql ("SELECT f.invoice_number, f.finding_type, f.action, coalesce($(Iso 'i.created_at'), ''), " +
        "replace(left(f.details, 120), '|', '/') FROM reconciliation_findings f LEFT JOIN invoices i ON i.invoice_number = f.invoice_number " +
        "WHERE f.run_id = $($run2.id)") -Strict))) {
        # Yedek aralığında kaybolan faturanın ERP kaydı ve haberleri her çalışmada görünür; ayrı sayıldıkları için hariç.
        if ($gapSet.ContainsKey($row[0]) -and $row[1] -in 'Serviste Yok', 'Tanınmayan Haber') { continue }
        $at = if ($row[3]) { [DateTimeOffset]::Parse($row[3]) } elseif ($accepted.ContainsKey($row[0])) { $accepted[$row[0]] } else { $null }
        Add-Violation $G5 $row[0] $at "$($row[1]) ($($row[2])): $($row[4])"
    } }
    if ($run2 -and $run2.status -ne 'Tamamlandı') { Add-Violation $G5 '-' $null "son mutabakat $($run2.status): $($run2.error)" }
}

# Simülatörün logu bir kez, en sonda kaydedilir (yeniden yaratılan container'ların logları Reset-Simulator'da kaydedildi).
Save-SimulatorLog

$erpNumbers = @{}
foreach ($row in (Get-Rows (Invoke-ErpSql 'SELECT DISTINCT invoice_number FROM invoices' -Strict))) { $erpNumbers[$row[0]] = $true }
foreach ($row in $service.Values) {
    if ($row[2] -and -not $erpNumbers.ContainsKey($row[0])) { Add-Violation $G1 $row[0] ([DateTimeOffset]::Parse($row[3])) "serviste $($row[1]) ($($row[2])), ERP'de kaydı yok" }
}
foreach ($row in (Get-Rows (Invoke-ErpSql ("SELECT invoice_number, count(*), $(Iso '(array_agg(received_at ORDER BY received_at))[2]') " +
    "FROM invoices GROUP BY invoice_number HAVING count(*) > 1") -Strict))) {
    Add-Violation $G2 $row[0] ([DateTimeOffset]::Parse($row[2])) "ERP'de $($row[1]) kayıt"
}
foreach ($row in (Get-Rows (Invoke-ErpSql ("SELECT c.invoice_number, $(Iso 'c.cancelled_at') " +
    "FROM cancellations c WHERE NOT EXISTS (SELECT 1 FROM invoices i WHERE i.invoice_number = c.invoice_number AND i.received_at < c.cancelled_at)") -Strict))) {
    Add-Violation $G3 $row[0] ([DateTimeOffset]::Parse($row[1])) 'iptal kaydı faturanın kaydından önce'
}
foreach ($line in (Get-Content $script:SimulatorLogFile -Encoding UTF8)) {
    if ($line -match '^(\S+?)(\.\d{1,3})?\d*Z\s.*ERP cancel invoice=(\S+) status=404 reason=notRecorded') {
        # docker'ın zamanı 9 kesir basamaklı; Parse en çok 7'yi okur, milisaniyeye kısaltılır.
        Add-Violation $G3 $Matches[3] ([DateTimeOffset]::Parse("$($Matches[1])$($Matches[2])Z")) 'iptal isteği ERP''ye faturadan önce geldi (simülatör logu)'
    }
}

# Koşunun sonundaki durum: mutabakat ERP'de kaydı bulunan Başarısız faturayı düzeltmiş olabilir.
$failedInvoices = Get-Rows (Invoke-InvoiceSql "SELECT invoice_number FROM invoices WHERE customer_code = '$RunId' AND status = 'Başarısız' ORDER BY 1")

# ---------------------------------------------------------------------------------------------------------------------------
# Sonuç
# ---------------------------------------------------------------------------------------------------------------------------
function Get-OpenFaults($At) {
    if (-not $At) { return '-' }
    $s = ($At - $LoadStart).TotalSeconds
    $open = @($executed | Where-Object { $_.Start -le $s -and $s -le $_.End } | ForEach-Object { "$($_.Order). $($_.Ad)" })
    if ($open.Count -eq 0) { 'yok' } else { $open -join ', ' }
}

$red = $violations.Count -gt 0
$verdict = if (-not $settled -and $red) { 'DURULMADI + KIRMIZI' } elseif (-not $settled) { 'DURULMADI' } elseif ($red) { 'KIRMIZI' } else { 'YEŞİL' }
$out = [Collections.Generic.List[string]]::new()
$out.Add("SONUÇ: $verdict")
$out.Add("Seed $Seed; aynı sırayla yeniden: .\chaos\kaos.ps1 -Seed $Seed$(if ($Rate -ne 20 -or $Duration -ne '10m') { " -Rate $Rate -Duration $Duration" })")
$out.Add("Koşu $RunName, $($startedAt.ToString('yyyy-MM-dd HH:mm'))-$((Get-Date).ToString('HH:mm')); yük $Rate/sn x $Duration, 202 alan $($accepted.Count) fatura ($RunId)")
$out.Add('')
$out.Add('Garantiler')
foreach ($g in $G1, $G2, $G3, $G4, $G5) {
    $count = @($violations | Where-Object { $_.Guarantee -eq $g }).Count
    $state = if (-not $settled -and $g -in $G4, $G5) { 'KONTROL EDİLMEDİ (durulmadı)' } elseif ($count -eq 0) { 'TAMAM' } else { "BOZULDU ($count fatura)" }
    $extra = if ($g -eq $G1 -and $executed.Key -contains 'veritabani-kaybi') { "; yedek aralığı kaybı ayrı: $($gapLost.Count)" } else { '' }
    $out.Add("  [$state] $g$extra")
}
$settleText = if ($settled) { "son arızadan $([Math]::Round(($settledAt - $lastFaultEnd).TotalMinutes, 1)) dk sonra" } else { "$SettleMinutes dk içinde olmadı" }
$out.Add("Durulma: $settleText (sınır $SettleMinutes dk)")
if (-not $settled) {
    $out.Add("  Kalan: outbox'ta Bekliyor $(Invoke-InvoiceSql "SELECT count(*) FROM erp_outbox WHERE status = 'Bekliyor'"), ERP'de gönderilmeyi bekleyen haber $(Invoke-ErpSql "SELECT count(*) FROM webhook_deliveries WHERE status IN ('Pending', 'Waiting')")")
}
if ($red) {
    $out.Add('')
    $out.Add('Bozulmalar (garanti | fatura | an | o sırada açık arızalar | ayrıntı); her garantiden en çok 20 satır')
    foreach ($g in $G1, $G2, $G3, $G4, $G5) {
        foreach ($v in @($violations | Where-Object { $_.Guarantee -eq $g } | Sort-Object At | Select-Object -First 20)) {
            $when = if ($v.At) { "$(Format-Offset ($v.At - $LoadStart).TotalSeconds) ($($v.At.ToLocalTime().ToString('HH:mm:ss')))" } else { '-' }
            $out.Add("  $g | $($v.Invoice) | $when | $(Get-OpenFaults $v.At) | $($v.Detail)")
        }
    }
}
$out.Add('')
$out.Add('Arıza sırası (gerçekleşen; yük başlangıcından itibaren dk:sn)')
foreach ($e in $executed) { $out.Add(("  {0}. {1}-{2}  {3}" -f $e.Order, (Format-Offset $e.Start), (Format-Offset $e.End), $e.Ad)) }
$out.Add('')
$out.Add('Bilgi')
$out.Add("  İptal istekleri: $(($cancelCodes.Keys | Sort-Object | ForEach-Object { "HTTP $_ x $($cancelCodes[$_])" }) -join ', ')")
$out.Add("  Başarısız fatura (operatörün önünde, garanti dışı): $($failedInvoices.Count)$(if ($failedInvoices.Count) { ' - ' + (($failedInvoices | Select-Object -First 5 | ForEach-Object { $_[0] }) -join ', ') })")
if ($run1) { $out.Add("  Mutabakat $($run1.id) (durulmadan sonra): $($run1.status), kontrol $($run1.checkedCount), düzeltilen $($run1.fixedCount), raporlanan $($run1.reportedCount)") }
if ($run2) { $out.Add("  Mutabakat $($run2.id) (son): $($run2.status), kontrol $($run2.checkedCount), düzeltilen $($run2.fixedCount), raporlanan $($run2.reportedCount)") }
if ($BackupAt) { $out.Add("  Veritabanı kaybı: yedek $($BackupAt.ToLocalTime().ToString('HH:mm:ss')), silme $($DeletedAt.ToLocalTime().ToString('HH:mm:ss')), yedek aralığında kaybolan $($gapLost.Count)$(if ($gapLost.Count) { ' - ' + (($gapLost | Sort-Object | Select-Object -First 5) -join ', ') })") }
$out.Add("  Dosyalar: chaos\results\$RunName\")

[IO.File]::WriteAllLines((Join-Path $RunDir 'sonuc.txt'), $out, [Text.UTF8Encoding]::new($true))
Write-Host ''
foreach ($line in $out) {
    $color = if ($line -like 'SONUÇ: YEŞİL*') { 'Green' } elseif ($line -like 'SONUÇ:*') { 'Red' } else { 'Gray' }
    Write-Host $line -ForegroundColor $color
}
