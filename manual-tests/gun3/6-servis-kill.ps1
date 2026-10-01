# Gün 3 - Madde 6: varsayılan oranlarla 200 fatura gönderirken Fatura Servisi'ni gönderim sürerken üç kez docker kill
# ile öldürüp yeniden başlat. Kuyruk boşaldığında kayıp ve çift kayıt sayısının 0 olduğunu göster. ~4 dk.
#
# Faturalar 50'şerlik 4 partide gönderilir; ilk üç partiden ~2 sn sonra (worker gönderirken) servis docker kill ile
# öldürülür (SIGKILL: kapanış kodu çalışmaz) ve docker compose start ile yeniden başlatılır.
# Öldürülme anında yarıda kalan gönderimler logda "ERP send start" satırı olup sonucu ("ERP send invoice=...") olmayan
# denemelerdir. Bu kayıtlar locked_until (60 sn) dolunca yeniden alınır; ikinci denemede servis simülatöre sorar,
# fatura oraya ulaşmışsa POST yapmadan referansını alır.
# Kayıp: 202 alınan bir faturanın serviste olmaması, ya da kuyruk boşaldığında Bekliyor kalması, ya da Gönderildi olup
# simülatörde olmaması.
. "$PSScriptRoot\_common.ps1"
# Script bir hatayla yarıda kesilirse simülatör değiştirilmiş ayarda kalıp, servis de öldürülmüş durumda kalıp sonraki
# testleri bozmasın: servis başlatılır, simülatör varsayılan ayarlarına döndürülür, hata yine yukarı iletilir.
trap { Write-Host "Hata: $_ - servis başlatılıyor, simülatör varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Invoke-Compose @('start', 'invoice-service') } catch { }; try { Restart-Simulator } catch { }; break }

Write-Title '6) 200 fatura gönderilirken servis 3 kez docker kill ile öldürülüyor -> kayıp 0, çift kayıt 0'

Wait-Service
Restart-Simulator

function Stop-ServiceHard([int]$No) {
    Write-Step "docker kill #$No (Fatura Servisi gönderim yaparken öldürülüyor)"
    $inFlight = @(Get-ServiceRows "SELECT count(*) FROM erp_outbox WHERE locked_until > now();")[0]
    Push-Location $RepoRoot
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $id = (& docker compose ps -q invoice-service).Trim()
        & docker kill $id 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'docker kill başarısız oldu.' }
        Write-Host "  Öldürüldü (o anda kilitli, yani gönderilmekte olan outbox kaydı: $inFlight). Yeniden başlatılıyor..."
    }
    finally { $ErrorActionPreference = $previous; Pop-Location }
    Invoke-Compose @('start', 'invoice-service')
    Wait-Service
    Write-Host '  Fatura Servisi yeniden ayakta.'
}

$numbers = @()
$accepted = 0
for ($batch = 1; $batch -le 4; $batch++) {
    Write-Step "Parti $batch`: 50 fatura"
    for ($i = 0; $i -lt 50; $i++) {
        $r = New-ServiceInvoice
        if ($r.HttpStatus -eq 202) { $accepted++; $numbers += $r.InvoiceNumber }
    }
    Write-Host "  $($numbers[-50]) .. $($numbers[-1])"
    if ($batch -le 3) {
        Start-Sleep -Seconds 2
        Stop-ServiceHard $batch
    }
}
$from = ($numbers | Sort-Object)[0]; $to = ($numbers | Sort-Object)[-1]

Write-Step 'Kuyruk boşalana kadar bekleniyor (öldürülme anında kilitli kalan kayıtlar 60 sn sonra yeniden alınır)'
$seconds = Wait-QueueDrained $from $to 900
Write-Host "  Kuyruk $seconds sn'de boşaldı."

# Yarıda kalan denemeler: başlangıç satırı var, sonuç satırı yok.
$started = @{}; $finished = @{}
foreach ($line in Get-ServiceLog) {
    # Alım kimliğiyle (claim) eşlenir: yarıda kalan son deneme aynı numarayla yeniden alınabilir.
    if ($line -match 'ERP send start invoice=(\S+) attempt=(\d+)/\d+ worker=\S+ claim=(\w+)' -and $numbers -contains $Matches[1]) { $started[$Matches[3]] = "$($Matches[1])#$($Matches[2])" }
    elseif ($line -match 'ERP send invoice=(\S+) attempt=(\d+)/\d+ worker=\S+ claim=(\w+)' -and $numbers -contains $Matches[1]) { $finished[$Matches[3]] = $true }
}
$cut = @($started.Keys | Where-Object { -not $finished.ContainsKey($_) } | ForEach-Object { $started[$_] } | Sort-Object)
$cutInvoices = @($cut | ForEach-Object { ($_ -split '#')[0] } | Sort-Object -Unique)
Write-Step "Öldürülme anında yarıda kalan denemeler: $($cut.Count)"
$cut | ForEach-Object { Write-Host "  $($_ -replace '#', ' deneme ')" }

Write-Step 'Karşılaştırma: servisteki her fatura simülatörün GET endpoint''iyle sorgulanıyor'
$c = Compare-Invoices -From $from -To $to

$where = "invoice_number BETWEEN '$from' AND '$to'"
Write-DbHeader 'Madde 6: 3 kez docker kill' "Fatura aralığı: $from .. $to"
Show-ServiceQuery "SELECT status, count(*) AS fatura, round(avg(send_attempt_count), 2) AS ort_deneme, max(send_attempt_count) AS max_deneme FROM invoices WHERE $where GROUP BY 1;"
if ($cutInvoices) {
    $list = "'" + ($cutInvoices -join "','") + "'"
    Show-ServiceQuery "SELECT invoice_number, status, erp_reference, send_attempt_count FROM invoices WHERE invoice_number IN ($list) ORDER BY 1;"
    Show-ErpQuery "SELECT invoice_number, count(*) AS kayit, string_agg(erp_reference || ' ' || behavior, ', ' ORDER BY id) AS kayitlar FROM invoices WHERE invoice_number IN ($list) GROUP BY 1 ORDER BY 1;"
}
Show-ErpQuery "SELECT invoice_number, count(*) AS kayit FROM invoices WHERE $where GROUP BY 1 HAVING count(*) > 1;"

$rows = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE $where;")[0]
$pending = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE $where AND status = 'Bekliyor';")[0]
$db = Get-DbComparison $from $to
$lost = (200 - $rows) + $pending + $db.SentMissing
Write-Host ''
$ok = Write-DbVerdict ('en az bir gönderim öldürülme anında yarıda kaldı; 200 POST 202; serviste 200 fatura, Bekliyor kalan 0; ' +
    'Gönderildi ama simülatörde olmayan 0 (kayıp 0); ' +
    'simülatörde birden fazla kaydı olan 0 (çift kayıt 0); referanslar aynı') `
    ("yarıda kalan $($cut.Count); $accepted POST 202; serviste $rows fatura, Bekliyor $pending; Gönderildi+yok $($db.SentMissing) (kayıp $lost); " +
     "birden fazla kayıt $($db.MultipleRecords); referans aynı $($db.ReferenceMatches)/$($db.SentFound); Başarısız $($db.FailedMissing + $db.FailedFound)") `
    ($cut.Count -gt 0 -and $accepted -eq 200 -and $rows -eq 200 -and $lost -eq 0 -and $db.MultipleRecords -eq 0 -and $db.ReferenceMatches -eq $db.SentFound -and $c.Unknown -eq 0)

Write-Result $ok "3 kez docker kill, $($cut.Count) gönderim yarıda kaldı; kayıp $lost, çift kayıt $($db.MultipleRecords); $($db.SentFound) Gönderildi"
