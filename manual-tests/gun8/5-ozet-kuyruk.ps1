# Özet sayfasındaki kuyruk değerleri veritabanıyla aynı: kuyrukta bekleyen, en eski bekleme, son bir dakikada gönderilen.
#
# Kuyruk boşalırken değerler her an değişir; bu yüzden her ölçümde API çağrısı iki veritabanı okumasının arasına alınır
# (veritabanı -> API -> veritabanı). Arada geçen sürede değer iki yönde de değişebilir (kuyruğa giren de çıkan da var;
# "son 1 dakika" kayan bir pencere, yeni gönderim girer, 60 sn'yi geçen çıkar). Bu yüzden API'nin değeri, iki okumanın
# her birinden en fazla aradaki olay sayısı kadar farklı olabilir; olaylar aynı aralık için veritabanından sayılır
# (kuyruk: created_at ya da processed_at aralıkta olan kayıt; son 1 dk: processed_at'i aralıkta ya da 60 sn öncesindeki
# aralıkta olan Tamamlandı kayıt). En eski bekleme iki okumanın arasında olmalı (saniyeye yuvarlama payı 1 sn).
# $Rounds ölçüm, $IntervalSeconds arayla. Kuyruk boşsa da çalışır (değerler 0 / boş).
# Ekran aynı /summary cevabını gösterir ve 10 saniyede bir yeniler; ekran görüntüsü kontrol listesinde ayrıca alınır.
param([int]$Rounds = 5, [int]$IntervalSeconds = 10)

. "$PSScriptRoot\_common.ps1"

Write-Title 'Özet: kuyruk değerleri veritabanıyla aynı'

# Özetin kullandığı tanımlar: Bekliyor kayıtları, en eskisinin created_at'i, son 60 sn'de Tamamlandı olanlar.
$dbSql = "SELECT to_char(now(), 'YYYY-MM-DD HH24:MI:SS.USOF') || ' ' || count(*) FILTER (WHERE status = 'Bekliyor') || ' ' || " +
    "coalesce(floor(extract(epoch FROM now() - min(created_at) FILTER (WHERE status = 'Bekliyor')))::text, '-') || ' ' || " +
    "count(*) FILTER (WHERE status = 'Tamamlandı' AND processed_at >= now() - interval '60 seconds') FROM erp_outbox;"

function Read-Db {
    $parts = @(Get-ServiceRows $dbSql)[0] -split ' '
    [pscustomobject]@{
        At = "$($parts[0]) $($parts[1])"; Queued = [int]$parts[2]
        Oldest = $(if ($parts[3] -eq '-') { $null } else { [long]$parts[3] }); Sent = [int]$parts[4]
    }
}

# İki okuma arasında (t1, t2] kuyruk sayısını ve "son 1 dk"yı değiştiren olaylar.
function Get-Events([string]$T1, [string]$T2) {
    $parts = @(Get-ServiceRows ("SELECT (count(*) FILTER (WHERE created_at > '$T1' AND created_at <= '$T2') + " +
        "count(*) FILTER (WHERE processed_at > '$T1' AND processed_at <= '$T2')) || ' ' || " +
        "(count(*) FILTER (WHERE status = 'Tamamlandı' AND processed_at > '$T1' AND processed_at <= '$T2') + " +
        "count(*) FILTER (WHERE status = 'Tamamlandı' AND processed_at > timestamptz '$T1' - interval '60 seconds' " +
        "AND processed_at <= timestamptz '$T2' - interval '60 seconds')) FROM erp_outbox;"))[0] -split ' '
    [pscustomobject]@{ Queue = [int]$parts[0]; Sent = [int]$parts[1] }
}

function Test-Near($Value, $A, $B, [int]$Events) { [math]::Abs($Value - $A) -le $Events -and [math]::Abs($Value - $B) -le $Events }

function Test-Between($Value, $A, $B, [int]$Slack = 0) {
    if ($null -eq $Value -or $null -eq $A -or $null -eq $B) { return ($null -eq $Value -and $null -eq $A -and $null -eq $B) }
    $Value -ge ([math]::Min($A, $B) - $Slack) -and $Value -le ([math]::Max($A, $B) + $Slack)
}

function Show([object]$v) { if ($null -eq $v) { '-' } else { "$v" } }

Write-DbHeader 'Her ölçümde veritabanı -> API -> veritabanı' 'SQL (özetin tanımları):'
Write-Host "  $dbSql" -ForegroundColor DarkGray
$rows = @(); $allOk = $true
for ($i = 1; $i -le $Rounds; $i++) {
    $before = Read-Db
    $api = (Get-Api '/api/v1/invoices/summary').Json
    $after = Read-Db
    $events = Get-Events $before.At $after.At
    $ok = (Test-Near $api.queuedCount $before.Queued $after.Queued $events.Queue) -and
          (Test-Between $api.oldestQueuedSeconds $before.Oldest $after.Oldest 1) -and
          (Test-Near $api.sentLastMinute $before.Sent $after.Sent $events.Sent)
    if (-not $ok) { $allOk = $false }
    $rows += [pscustomobject]@{
        Saat                  = (Get-Date -Format 'HH:mm:ss')
        'Kuyruk DB / API / DB (olay)' = "$($before.Queued) / $($api.queuedCount) / $($after.Queued) ($($events.Queue))"
        'En eski sn DB / API / DB' = "$(Show $before.Oldest) / $(Show $api.oldestQueuedSeconds) / $(Show $after.Oldest)"
        'Son 1 dk DB / API / DB (olay)' = "$($before.Sent) / $($api.sentLastMinute) / $($after.Sent) ($($events.Sent))"
        Sonuç                 = $(if ($ok) { 'aynı' } else { 'FARKLI' })
    }
    if ($i -lt $Rounds) { Start-Sleep -Seconds $IntervalSeconds }
}
$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

$check = Write-DbVerdict "$Rounds ölçümün hepsinde API değerleri iki okumadan en fazla aradaki olay sayısı kadar farklı" `
    "$(@($rows | Where-Object { $_.Sonuç -eq 'aynı' }).Count) / $Rounds" $allOk

Write-Result $check 'Özetteki kuyruk sayısı, en eski bekleme ve son bir dakikada gönderilen veritabanıyla aynı'
