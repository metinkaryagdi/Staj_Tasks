# Gün 5 - Kontrol listesi 8: Fatura Servisi'nin iki kopyası çalışırken aynı anda elle de mutabakat başlat:
# aynı anda yalnızca bir çalışma olur, diğer istekler 409 alır. ~2 dk.
#
#   A) Kilit başka bir oturumda tutulurken (başka bir kopyanın çalışması gibi): iki kopyaya da POST -> ikisi de 409;
#      kilit bırakılınca POST -> 202.
#   B) Her iki kopya da dakikada bir kendiliğinden çalışırken 30 POST aynı anda, kopyalara dağıtılarak: 202 alanların sayısı
#      kadar çalışma oluşur, geri kalanı 409; hiçbir iki çalışmanın zaman aralığı üst üste binmez.
# İkinci kopya (invoice-service-2, port 5091) script tarafından başlatılır ve sonunda durdurulur.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: $_ - ikinci kopya durduruluyor, servis varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Invoke-Compose @('--profile', 'iki-kopya', 'stop', 'invoice-service-2'); Restart-InvoiceService } catch { }; break }

Write-Title 'Kontrol listesi 8) İki kopya + elle başlatma: aynı anda yalnızca bir çalışma, diğer istek 409'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
Restart-Simulator (Get-SimSettings -NoEvents)
Restart-InvoiceService @{ Reconciliation__IntervalMinutes = 1 } -WithSecondCopy
$startedAt = @(Get-ServiceRows "SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US');")[0]

# --- A) Kilit başka oturumda ---------------------------------------------------------------------------------------------
Write-Step 'A) Kilit 20 sn boyunca başka bir veritabanı oturumunda tutuluyor'
$lockJob = Start-Job -ScriptBlock {
    param($root)
    Set-Location $root
    & docker compose exec -T invoice-db psql -U invoice -d invoice_service -c 'SELECT pg_advisory_lock(7300001); SELECT pg_sleep(20);'
} -ArgumentList $RepoRoot
Start-Sleep -Seconds 4
Show-ServiceQuery "SELECT locktype, objid, granted, pid FROM pg_locks WHERE locktype = 'advisory';"
$one = Start-Reconciliation $ServiceUrl
$two = Start-Reconciliation $Service2Url
Write-Host "  kopya 1 (5090): HTTP $($one.Status)   kopya 2 (5091): HTTP $($two.Status)"
Check (Write-DbVerdict 'kilit tutulurken iki kopya da 409 döner' "$($one.Status), $($two.Status)" ($one.Status -eq 409 -and $two.Status -eq 409))

Write-Host '  Kilidin bırakılması bekleniyor...' -ForegroundColor DarkGray
Wait-Job $lockJob | Out-Null
Remove-Job $lockJob
Start-Sleep -Seconds 1
# Zamanlanmış çalışma araya girmiş olabilir; bu durumda bitmesini bekleyip yeniden denenir.
$after = $null
for ($i = 0; $i -lt 20 -and (-not $after -or $after.Status -ne 202); $i++) {
    $after = Start-Reconciliation $ServiceUrl
    if ($after.Status -ne 202) { Start-Sleep -Seconds 1 }
}
Check (Write-DbVerdict 'kilit bırakılınca POST 202 döner' "$($after.Status)" ($after.Status -eq 202))
if ($after.Status -eq 202) { Wait-RunDone $after.RunId | Out-Null }

# --- B) Aynı anda 30 POST -------------------------------------------------------------------------------------------------
Write-Step 'B) İki kopyaya 30 POST aynı anda gönderiliyor'
$tasks = @(1..30 | ForEach-Object {
    $url = if ($_ % 2 -eq 1) { $ServiceUrl } else { $Service2Url }
    $script:Http.PostAsync("$url/api/v1/reconciliation-runs", $null)
})
[Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks)
$codes = @($tasks | ForEach-Object { [int]$_.Result.StatusCode })
$accepted = @($codes | Where-Object { $_ -eq 202 }).Count
$conflict = @($codes | Where-Object { $_ -eq 409 }).Count
Write-Host "  202: $accepted   409: $conflict   diğer: $(30 - $accepted - $conflict)"

# Çalışıyor olan kalmayana kadar bekle (zamanlanmış çalışmalar da dahil).
$watch = [Diagnostics.Stopwatch]::StartNew()
while ((Count-Service "SELECT count(*) FROM reconciliation_runs WHERE status = 'Çalışıyor';") -gt 0 -and $watch.Elapsed.TotalSeconds -lt 90) { Start-Sleep -Seconds 1 }

Write-DbHeader 'Fatura Servisi' 'Bu script sırasındaki çalışmalar (başlangıç zamanına göre)'
Show-ServiceQuery ("SELECT id, to_char(started_at AT TIME ZONE 'UTC', 'HH24:MI:SS.MS') AS basladi, to_char(finished_at AT TIME ZONE 'UTC', 'HH24:MI:SS.MS') AS bitti, status " +
                   "FROM reconciliation_runs WHERE started_at >= '$startedAt+00' ORDER BY id;")
$range = "started_at >= '$startedAt+00'"
$overlap = Count-Service ("SELECT count(*) FROM reconciliation_runs a JOIN reconciliation_runs b ON a.id < b.id " +
                          "AND a.started_at < coalesce(b.finished_at, now()) AND b.started_at < coalesce(a.finished_at, now()) " +
                          "WHERE a.$range AND b.$range;")
$notDone = Count-Service "SELECT count(*) FROM reconciliation_runs WHERE $range AND status <> 'Tamamlandı';"
$bBegan = Count-Service "SELECT count(*) FROM reconciliation_runs WHERE $range;"

Check (Write-DbVerdict '30 isteğin hepsi 202 ya da 409' "202: $accepted, 409: $conflict" (($accepted + $conflict) -eq 30 -and $accepted -ge 1))
Check (Write-DbVerdict 'hiçbir iki çalışmanın zaman aralığı üst üste binmiyor' "$overlap çift" ($overlap -eq 0))
Check (Write-DbVerdict 'bütün çalışmalar Tamamlandı' "$notDone Tamamlandı olmayan / $bBegan çalışma" ($notDone -eq 0))

Invoke-Compose @('--profile', 'iki-kopya', 'stop', 'invoice-service-2')
Restart-InvoiceService
Restart-Simulator
Write-Result $allPassed 'iki kopya ve elle başlatma: aynı anda yalnızca bir çalışma, diğer istekler 409'
