# İz Yapısı 2 ve Örnekleme Kuralı 2 için: saklanan bir faturanın yolculuğu, mutabakatın düzeltmesi ve operatörün yeniden
# gönderimi dahil baştan sona izinde; 3'ten az denemede kalıcı olarak Başarısız olan faturanın izi de saklanıyor.
#   .\manual-tests\gun13\4-mutabakat-yeniden-gonderim.ps1
# Kendi boş volume'leriyle (staj-tasks_*-db-data-gun13-hedefli) açılır, servis güncel koddan derlenir; Collector asıl
# config'iyle (30 dk karar süresi) çalışır ve yeniden başlatılmaz. Üç fatura:
#   A: simülatör 500 verir, 3 kez denenir; sonra kabul eder ama karar haberini göndermez (LostDecisionRate 100), fatura
#      İşleme Alındı'da kalır. 2 dk (StuckAfterMinutes) sonra mutabakat elle başlatılır, kararı ERP'den alıp yazar.
#   B: simülatör 500 verir, varsayılan deneme hakkıyla (10) Başarısız olur; sonra simülatör kabul eder, operatör yeniden
#      gönderir.
#   C: servis deneme hakkı 2 ile açılır (compose.iki-deneme.yml), 2 denemede Başarısız olur ve öyle kalır.
# Son adımdan sonra karar süresi + pay beklenir; üç faturanın izi Jaeger'dan alınıp adımları kontrol edilir.
# Çıktı output\gun13-4-mutabakat-yeniden-gonderim.txt.
. "$PSScriptRoot\_common.ps1"
Use-Gun10Volumes 'gun13-hedefli'

$out = Join-Path $OutputDir 'gun13-4-mutabakat-yeniden-gonderim.txt'
$report = [Collections.Generic.List[string]]::new()
function Write-Line([string]$Text) { Write-Host $Text; $report.Add($Text) }
function Get-Status([string]$Number) { @(Get-ServiceRows "SELECT status, send_attempt_count FROM invoices WHERE invoice_number = '$Number';")[0] }

# Servisi verilen ek compose dosyasıyla (ya da onsuz) yeniden açar; veritabanları ve simülatör yerinde kalır.
function Restart-Service([string]$Extra = '') {
    $files = @((Join-Path $RepoRoot 'docker-compose.yml'), (Join-Path $RepoRoot 'manual-tests\gun10\compose.volumes.yml'))
    if ($Extra) { $files += $Extra }
    $env:COMPOSE_FILE = $files -join ';'
    Invoke-Compose @('up', '-d', '--force-recreate', '--no-deps', 'invoice-service')
    Wait-Health $ServiceUrl
}

function Wait-Until([scriptblock]$Condition, [int]$TimeoutSeconds, [string]$What) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $Condition)) {
        if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw "$TimeoutSeconds sn içinde $What olmadı." }
        Start-Sleep -Seconds 2
    }
    Write-Host ("  {0:N0} sn: {1}" -f $watch.Elapsed.TotalSeconds, $What) -ForegroundColor DarkGray
}

Write-Title 'Mutabakat düzeltmesi, yeniden gönderim ve 2 denemede Başarısız olan faturanın izi'
# --force-recreate: servisler yeni veritabanlarına bağlanıp migration'larını orada çalıştırsın; --build: güncel kod.
Invoke-Compose @('up', '-d', '--build', '--force-recreate', 'invoice-db', 'erp-db', 'invoice-service', 'erp-simulator')
Wait-Health $ServiceUrl
Wait-Health $SimulatorUrl
if ([int]@(Get-ServiceRows 'SELECT count(*) FROM invoices;')[0] -ne 0) { throw "gun13-hedefli volume'ü boş değil; docker volume rm ile silip yeniden çalıştırın." }
$since = [DateTimeOffset]::UtcNow.AddSeconds(-5)

try {
    Write-Step 'A: 3 deneme, sonra karar haberi gelmiyor'
    Restart-Simulator (Get-SimSettings 'ServerError')
    $a = (New-ServiceInvoice).InvoiceNumber
    Wait-Until { [int](Get-Status $a).Split('|')[1] -ge 3 } 120 "$a 3 kez denendi"
    Restart-Simulator (Get-SimSettings 'Success' @{ LostDecisionRate = 100 })
    Wait-Until { (Get-Status $a).StartsWith('İşleme Alındı|') } 180 "$a İşleme Alındı (karar haberi gönderilmedi)"
    $aStuckAt = [DateTimeOffset]::UtcNow

    Write-Step 'B: varsayılan deneme hakkıyla (10) Başarısız'
    Restart-Simulator (Get-SimSettings 'ServerError')
    $b = (New-ServiceInvoice).InvoiceNumber
    Wait-Until { (Get-Status $b).StartsWith('Başarısız|') } 900 "$b Başarısız"

    Write-Step 'C: deneme hakkı 2 ile Başarısız'
    Restart-Service (Join-Path $PSScriptRoot 'compose.iki-deneme.yml')
    $c = (New-ServiceInvoice).InvoiceNumber
    Wait-Until { (Get-Status $c).StartsWith('Başarısız|') } 300 "$c Başarısız"
    Restart-Service

    Write-Step 'B: simülatör kabul ediyor, operatör yeniden gönderiyor'
    Restart-Simulator (Get-SimSettings 'Success')
    $resend = Send-ServiceResend $b
    if ($resend.HttpStatus -ne 202) { throw "Yeniden gönderim 202 almadı: $($resend.HttpStatus) $($resend.Body)" }
    Wait-InvoicesIn @($b) @('Onaylandı', 'Reddedildi') 180 'karar aldı' | Out-Null
    Wait-EventsDone @($b) 120 | Out-Null

    Write-Step 'A: mutabakat (takılı sayılması için 2 dk dolana kadar beklenir)'
    $left = 130 - ([DateTimeOffset]::UtcNow - $aStuckAt).TotalSeconds
    if ($left -gt 0) { Start-Sleep -Seconds ([int]$left) }
    $run = Invoke-Reconciliation
    Write-Host "  Mutabakat çalışması $($run.run.id): $($run.run.status), düzeltilen $($run.run.fixedCount)"
    Wait-Until { -not (Get-Status $a).StartsWith('İşleme Alındı|') } 30 "$a mutabakatla düzeltildi"
}
finally { Restart-Simulator }

$wait = $DecisionWaitSeconds + 60
Write-Step "Collector'ın kararları için $wait sn bekleniyor"
Start-Sleep -Seconds $wait

Write-Title 'Sonuç'
$checks = @()
foreach ($n in $a, $b, $c) {
    $row = (Get-Status $n).Split('|')
    $trace = Get-InvoiceTrace $n $since
    Show-Trace $trace "gun13-4-iz-$n.txt"
    $spans = $trace.Spans
    $attempts = @($spans | Where-Object Name -eq 'outbox.attempt' | Sort-Object Start)
    $post = @($spans | Where-Object { $_.Service -eq 'invoice-service' -and $_.Name -like 'POST /api/v1/invoices*' }).Count
    $fix = @($spans | Where-Object Name -eq 'reconciliation.fix')
    $re = @($spans | Where-Object Name -eq 'invoice.resend')
    $outcomes = ($attempts | ForEach-Object { "$($_.Tags['outbox.attempt']):$($_.Tags['outbox.outcome'])" }) -join ' '
    Write-Line "$n  durum $($row[0]), send_attempt_count $($row[1]); trace $($trace.TraceId), $($spans.Count) span"
    Write-Line "  oluşturma $post; denemeler $outcomes; reconciliation.fix $($fix.Count)$(if ($fix) { " (invoice.status=$($fix[0].Tags['invoice.status']))" }); invoice.resend $($re.Count)"
    $checks += [pscustomobject]@{ Number = $n; Status = $row[0]; Attempts = $attempts; Post = $post; Fix = $fix; Resend = $re }
}
$report | Set-Content $out -Encoding UTF8

$ca, $cb, $cc = $checks
$okA = $ca.Post -ge 1 -and $ca.Attempts.Count -ge 3 -and $ca.Fix.Count -eq 1 -and $ca.Fix[0].Tags['invoice.status'] -eq $ca.Status
# B: 10 deneme (hepsi başarısız), yeniden gönderim, sonra 1. deneme Sent; yeniden gönderim span'i son 10 denemeden sonra.
$okB = $cb.Post -ge 1 -and $cb.Attempts.Count -eq 11 -and $cb.Resend.Count -eq 1 -and
    $cb.Attempts[-1].Tags['outbox.outcome'] -eq 'Sent' -and $cb.Resend[0].Start -gt $cb.Attempts[-2].Start -and $cb.Resend[0].Start -lt $cb.Attempts[-1].Start
$okC = $cc.Status -eq 'Başarısız' -and $cc.Post -ge 1 -and $cc.Attempts.Count -eq 2 -and $cc.Attempts[-1].Tags['outbox.outcome'] -eq 'Failed'
Write-Result $okA "A ($a): izi saklandı, oluşturma, $($ca.Attempts.Count) deneme ve mutabakatın düzeltmesi tek trace'te"
Write-Result $okB "B ($b): izi saklandı, 10 deneme, operatörün yeniden gönderimi ve ardından gönderim tek trace'te"
Write-Result $okC "C ($c): 2 denemede kalıcı olarak Başarısız, izi saklandı"
