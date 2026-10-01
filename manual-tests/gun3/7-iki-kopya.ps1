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

try {
    # Başlatma da try içinde: kopya açılırken (ör. health beklenirken) hata olursa finally onu yine durdurur.
    Write-Step 'İkinci kopya (invoice-service-2) başlatılıyor'
    Invoke-Compose @('--profile', 'iki-kopya', 'up', '-d', '--build', 'invoice-service-2')
    $ServiceUrl = $ServiceUrl2
    Wait-Service
    $ServiceUrl = $ServiceUrl1

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

    # Her denemenin zaman aralığı (logdaki "send start" .. sonuç satırı, alım kimliğiyle eşlenir) ve onu hangi kopyanın yaptığı.
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $intervals = @()
    foreach ($service in 'invoice-service', 'invoice-service-2') {
        $open = @{}
        foreach ($line in Get-CopyLog $service) {
            if ($line -match '^(\S+ \S+) info: .*ERP send start invoice=(\S+) attempt=(\d+)/\d+ worker=(\S+) claim=(\w+)' -and $numbers -contains $Matches[2]) {
                $open[$Matches[5]] = [pscustomobject]@{
                    Invoice = $Matches[2]; Worker = $Matches[4]; End = $null
                    Start = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss.fff', $inv) }
            }
            elseif ($line -match '^(\S+ \S+) info: .*ERP send invoice=(\S+) attempt=(\d+)/\d+ worker=\S+ claim=(\w+)' -and $open.ContainsKey($Matches[4])) {
                $key = $Matches[4]
                $open[$key].End = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss.fff', $inv)
                $intervals += $open[$key]
                $open.Remove($key)
            }
        }
    }
    $perWorker = $intervals | Group-Object Worker | ForEach-Object { "$($_.Name)=$($_.Count)" }

    # Aynı faturanın, farklı kopyalarda yapılmış iki denemesi zamanda üst üste biniyor mu? (0 olmalı)
    $overlaps = 0
    $invoicesByBoth = 0
    foreach ($group in $intervals | Group-Object Invoice) {
        $list = @($group.Group | Sort-Object Start)
        if (@($list | Select-Object -ExpandProperty Worker -Unique).Count -gt 1) { $invoicesByBoth++ }
        for ($i = 0; $i -lt $list.Count; $i++) {
            for ($j = $i + 1; $j -lt $list.Count; $j++) {
                if ($list[$i].Worker -ne $list[$j].Worker -and $list[$j].Start -lt $list[$i].End -and $list[$i].Start -lt $list[$j].End) { $overlaps++ }
            }
        }
    }

    # İki kopya gerçekten aynı anda çalıştı mı: bütün aralıklar zaman çizgisinde taranır.
    $events = foreach ($iv in $intervals) {
        [pscustomobject]@{ Time = $iv.Start; Delta = 1; Worker = $iv.Worker; Order = 1 }
        [pscustomobject]@{ Time = $iv.End; Delta = -1; Worker = $iv.Worker; Order = 0 }
    }
    $active = @{}; $bothActive = $false; $maxTotal = 0
    foreach ($e in $events | Sort-Object Time, Order) {
        $active[$e.Worker] = [int]$active[$e.Worker] + $e.Delta
        $busy = @($active.Keys | Where-Object { $active[$_] -gt 0 })
        if ($busy.Count -ge 2) { $bothActive = $true }
        $total = ($active.Values | Measure-Object -Sum).Sum
        if ($total -gt $maxTotal) { $maxTotal = $total }
    }

    Write-Step 'Denemeleri hangi kopya yaptı (iki kopyanın logları, deneme başlangıç..bitiş aralıkları)'
    Write-Host "  Deneme sayısı kopya başına: $($perWorker -join ', ')"
    Write-Host "  İki kopya aynı anda gönderim yaptı mı: $(if ($bothActive) { 'evet' } else { 'HAYIR' }); aynı anda en fazla $maxTotal gönderim (kopya başına en fazla 10)"
    Write-Host "  Farklı denemeleri iki kopya tarafından yapılmış fatura: $invoicesByBoth (bir kopya bekleyip bıraktığı faturayı diğeri alabilir; bu normal)"
    Write-Host "  Aynı faturanın iki kopyadaki denemelerinin zamanda üst üste bindiği durum: $overlaps"

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
    $ok = Write-DbVerdict ('500 POST 202 (iki kopyaya bölünmüş); iki kopya aynı anda gönderim yaptı; aynı faturayı iki kopya hiçbir an birlikte göndermedi; ' +
        'simülatörde birden fazla kaydı olan 0; Gönderildi ama simülatörde olmayan 0; referanslar aynı') `
        ("$($numbers.Count) POST 202; $($perWorker -join ', '); aynı anda çalıştılar: $bothActive; üst üste binen $overlaps; " +
         "birden fazla kayıt $($db.MultipleRecords); Gönderildi+yok $($db.SentMissing); referans aynı $($db.ReferenceMatches)/$($db.SentFound)") `
        ($numbers.Count -eq 500 -and @($perWorker).Count -eq 2 -and $bothActive -and $overlaps -eq 0 -and $db.MultipleRecords -eq 0 -and
         $db.SentMissing -eq 0 -and $db.ReferenceMatches -eq $db.SentFound -and $c.Unknown -eq 0)
}
finally {
    $ServiceUrl = $ServiceUrl1
    Write-Step 'İkinci kopya durduruluyor'
    Invoke-Compose @('--profile', 'iki-kopya', 'stop', 'invoice-service-2')
}

Write-Result $ok "iki kopya: $($perWorker -join ', '); çift kayıt $($db.MultipleRecords); $($db.SentFound) Gönderildi, $($db.FailedMissing + $db.FailedFound) Başarısız"
