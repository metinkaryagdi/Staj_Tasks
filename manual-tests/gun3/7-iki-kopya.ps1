# Gün 3 - Madde 7: Fatura Servisi'nin iki kopyasını aynı veritabanına bağlı olarak aynı anda çalıştır, varsayılan
# oranlarla 500 fatura gönder. Simülatörde çift kayıt sayısının 0 olduğunu göster. ~3 dk.
#
# İkinci kopya docker-compose.yml'deki invoice-service-2 (profil: iki-kopya, port 5091); script onu başlatır ve sonunda
# durdurur. Faturalar sırayla bir kopyaya, bir diğerine POST edilir. İki kopyanın worker'ları aynı erp_outbox tablosundan
# kayıt alır: FOR UPDATE SKIP LOCKED ve locked_until/locked_by sayesinde bir kaydı aynı anda yalnızca biri alır.
# Servis loglarından her denemeyi hangi kopyanın yaptığı okunur: hiçbir deneme iki kopyada birden görünmemeli.
. "$PSScriptRoot\_common.ps1"

Write-Title '7) İki servis kopyası aynı veritabanında -> 500 fatura, simülatörde çift kayıt 0'

$ServiceUrl1 = 'http://localhost:5090'
$ServiceUrl2 = 'http://localhost:5091'

function Get-CopyLog([string]$Service) {
    Push-Location $RepoRoot
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & docker compose --profile iki-kopya logs $Service --no-log-prefix 2>$null }
    finally { $ErrorActionPreference = $previous; Pop-Location }
}

Wait-Service
Restart-Simulator
Write-Step 'İkinci kopya (invoice-service-2) başlatılıyor'
Invoke-Compose @('--profile', 'iki-kopya', 'up', '-d', '--build', 'invoice-service-2')
$ServiceUrl = $ServiceUrl2
Wait-Service
$ServiceUrl = $ServiceUrl1

try {
    $workers = @{}
    foreach ($service in 'invoice-service', 'invoice-service-2') {
        $line = Get-CopyLog $service | Where-Object { $_ -match 'Outbox worker started worker=(\S+)' } | Select-Object -Last 1
        if ($line -match 'worker=(\S+)') { $workers[$service] = $Matches[1] }
        Write-Host "  $service -> worker=$($workers[$service])"
    }
    if ($workers.Count -ne 2 -or $workers['invoice-service'] -eq $workers['invoice-service-2']) { throw 'İki kopyanın worker kimlikleri okunamadı ya da aynı.' }

    Write-Step '500 fatura oluşturuluyor: sırayla bir kopyaya, bir diğerine'
    $numbers = @(); $accepted = @{ $ServiceUrl1 = 0; $ServiceUrl2 = 0 }
    for ($i = 0; $i -lt 500; $i++) {
        $ServiceUrl = if ($i % 2 -eq 0) { $ServiceUrl1 } else { $ServiceUrl2 }
        $r = New-ServiceInvoice
        if ($r.HttpStatus -eq 202) { $accepted[$ServiceUrl]++; $numbers += $r.InvoiceNumber }
    }
    $ServiceUrl = $ServiceUrl1
    $sorted = $numbers | Sort-Object
    $from = $sorted[0]; $to = $sorted[-1]
    Write-Host "  $from .. $to : 5090'a $($accepted[$ServiceUrl1]), 5091'e $($accepted[$ServiceUrl2]) fatura 202 ile kabul edildi"

    Write-Step 'Kuyruk boşalana kadar bekleniyor'
    $seconds = Wait-QueueDrained $from $to 900
    Write-Host "  Kuyruk $seconds sn'de boşaldı."

    # Her denemeyi (fatura + deneme numarası) hangi kopya yaptı?
    $byAttempt = @{}
    foreach ($service in 'invoice-service', 'invoice-service-2') {
        foreach ($line in Get-CopyLog $service) {
            if ($line -match 'ERP send invoice=(\S+) attempt=(\d+)/\d+ worker=(\S+)' -and $numbers -contains $Matches[1]) {
                $key = "$($Matches[1])#$($Matches[2])"
                if (-not $byAttempt.ContainsKey($key)) { $byAttempt[$key] = @() }
                $byAttempt[$key] += $Matches[3]
            }
        }
    }
    $both = @($byAttempt.Keys | Where-Object { $byAttempt[$_].Count -gt 1 })
    $perWorker = $byAttempt.Values | ForEach-Object { $_ } | Group-Object | ForEach-Object { "$($_.Name)=$($_.Count)" }
    $invoicesByBoth = @($numbers | Where-Object {
        $n = $_; @($byAttempt.Keys | Where-Object { $_ -like "$n#*" } | ForEach-Object { $byAttempt[$_] } | Sort-Object -Unique).Count -gt 1 }).Count
    Write-Step 'Denemeleri hangi kopya yaptı (servis logları)'
    Write-Host "  Deneme sayısı kopya başına: $($perWorker -join ', ')"
    Write-Host "  Farklı denemeleri iki kopya tarafından yapılmış fatura: $invoicesByBoth (bir kopya bekleyip bıraktığı faturayı diğeri alabilir; bu normal)"
    Write-Host "  Aynı denemesi iki kopyada birden görünen: $($both.Count)"

    Write-Step 'Karşılaştırma: servisteki her fatura simülatörün GET endpoint''iyle sorgulanıyor'
    $c = Compare-Invoices -From $from -To $to

    $where = "invoice_number BETWEEN '$from' AND '$to'"
    Write-DbHeader 'Madde 7: iki kopya, 500 fatura' "Fatura aralığı: $from .. $to"
    Show-ServiceQuery "SELECT status, count(*) AS fatura, round(avg(send_attempt_count), 2) AS ort_deneme FROM invoices WHERE $where GROUP BY 1;"
    Show-ServiceQuery "SELECT o.status, count(*) AS kayit, count(locked_by) AS hala_kilitli FROM erp_outbox o WHERE $where GROUP BY 1;"
    Show-ErpQuery "SELECT count(*) AS kayit, count(DISTINCT invoice_number) AS farkli_fatura FROM invoices WHERE $where;"
    Show-ErpQuery "SELECT invoice_number, count(*) AS kayit FROM invoices WHERE $where GROUP BY 1 HAVING count(*) > 1;"
    $db = Get-DbComparison $from $to
    Write-Host ''
    $ok = Write-DbVerdict ('500 POST 202 (iki kopyaya bölünmüş); iki kopya da gönderim yaptı; hiçbir deneme iki kopyada birden yok; ' +
        'simülatörde birden fazla kaydı olan 0; Gönderildi ama simülatörde olmayan 0; referanslar aynı') `
        ("$($numbers.Count) POST 202; $($perWorker -join ', '); iki kopyada birden görünen deneme $($both.Count); " +
         "birden fazla kayıt $($db.MultipleRecords); Gönderildi+yok $($db.SentMissing); referans aynı $($db.ReferenceMatches)/$($db.SentFound)") `
        ($numbers.Count -eq 500 -and @($perWorker).Count -eq 2 -and $both.Count -eq 0 -and $db.MultipleRecords -eq 0 -and
         $db.SentMissing -eq 0 -and $db.ReferenceMatches -eq $db.SentFound -and $c.Unknown -eq 0)
}
finally {
    $ServiceUrl = $ServiceUrl1
    Write-Step 'İkinci kopya durduruluyor'
    Invoke-Compose @('--profile', 'iki-kopya', 'stop', 'invoice-service-2')
}

Write-Result $ok "iki kopya: $($perWorker -join ', '); çift kayıt $($db.MultipleRecords); $($db.SentFound) Gönderildi, $($db.FailedMissing + $db.FailedFound) Başarısız"
