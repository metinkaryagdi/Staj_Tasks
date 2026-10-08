# Özet sayfasındaki kuyruk değerleri veritabanıyla aynı: kuyrukta bekleyen, en eski bekleme, son bir dakikada gönderilen.
#
# Kuyruk boşalırken değerler her an değişir; bu yüzden her ölçümde API çağrısı iki veritabanı okumasının arasına alınır
# (veritabanı -> API -> veritabanı) ve API'nin değeri iki okumanın arasında olmalıdır (en eski bekleme için saniyeye
# yuvarlama payı 1 sn). $Rounds ölçüm, $IntervalSeconds arayla. Kuyruk boşsa da çalışır (değerler 0 / boş).
# Ekran aynı /summary cevabını gösterir ve 10 saniyede bir yeniler; ekran görüntüsü kontrol listesinde ayrıca alınır.
param([int]$Rounds = 5, [int]$IntervalSeconds = 10)

. "$PSScriptRoot\_common.ps1"

Write-Title 'Özet: kuyruk değerleri veritabanıyla aynı'

# Özetin kullandığı tanımlar: Bekliyor kayıtları, en eskisinin created_at'i, son 60 sn'de Tamamlandı olanlar.
$dbSql = "SELECT count(*) FILTER (WHERE status = 'Bekliyor') || ' ' || " +
    "coalesce(floor(extract(epoch FROM now() - min(created_at) FILTER (WHERE status = 'Bekliyor')))::text, '-') || ' ' || " +
    "count(*) FILTER (WHERE status = 'Tamamlandı' AND processed_at >= now() - interval '60 seconds') FROM erp_outbox;"

function Read-Db {
    $parts = @(Get-ServiceRows $dbSql)[0] -split ' '
    [pscustomobject]@{
        Queued = [int]$parts[0]; Oldest = $(if ($parts[1] -eq '-') { $null } else { [long]$parts[1] }); Sent = [int]$parts[2]
    }
}

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
    $ok = (Test-Between $api.queuedCount $before.Queued $after.Queued) -and
          (Test-Between $api.oldestQueuedSeconds $before.Oldest $after.Oldest 1) -and
          (Test-Between $api.sentLastMinute $before.Sent $after.Sent)
    if (-not $ok) { $allOk = $false }
    $rows += [pscustomobject]@{
        Saat                  = (Get-Date -Format 'HH:mm:ss')
        'Kuyruk DB / API / DB' = "$($before.Queued) / $($api.queuedCount) / $($after.Queued)"
        'En eski sn DB / API / DB' = "$(Show $before.Oldest) / $(Show $api.oldestQueuedSeconds) / $(Show $after.Oldest)"
        'Son 1 dk DB / API / DB' = "$($before.Sent) / $($api.sentLastMinute) / $($after.Sent)"
        Sonuç                 = $(if ($ok) { 'aynı' } else { 'FARKLI' })
    }
    if ($i -lt $Rounds) { Start-Sleep -Seconds $IntervalSeconds }
}
$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

$check = Write-DbVerdict "$Rounds ölçümün hepsinde API değerleri iki veritabanı okumasının arasında" `
    "$(@($rows | Where-Object { $_.Sonuç -eq 'aynı' }).Count) / $Rounds" $allOk

Write-Result $check 'Özetteki kuyruk sayısı, en eski bekleme ve son bir dakikada gönderilen veritabanıyla aynı'
