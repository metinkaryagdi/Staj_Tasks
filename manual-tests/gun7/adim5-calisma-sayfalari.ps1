# Gün 7 - Adım 5: mutabakat çalışma listesi sayfalı (GET /reconciliation-runs?page=&pageSize=, en fazla 50). ~20 sn.
#
#   Çalışma sayısı 120'nin altındaysa eksik kalan kadar tamamlanmış çalışma veritabanına eklenir (started_by = QA7-sayfa).
#   Sonra liste 50'lik sayfalarla baştan sona okunur: her çalışma bir kez, en yeni üstte, veritabanıyla aynı sırada; toplam ve
#   sayfa sayısı doğru; 51 ve 0 sayfa boyutu, 0. sayfa 400; son sayfadan sonrası boş.
#
# Önce servisin yeni kodla derlenmiş olması gerekir: docker compose up -d --build invoice-service
. "$PSScriptRoot\_common.ps1"

Write-Title 'Adım 5) Mutabakat çalışma listesi sayfa sayfa'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
$existing = Count-Service 'SELECT count(*) FROM reconciliation_runs;'
if ($existing -lt 120) {
    $missing = 120 - $existing
    Write-Step "$existing çalışma var; $missing tamamlanmış çalışma ekleniyor"
    Invoke-ServiceSql ("INSERT INTO reconciliation_runs (started_at, finished_at, status, checked_count, fixed_count, reported_count, started_by) " +
        "SELECT now() - make_interval(mins => g), now() - make_interval(mins => g) + interval '1 second', 'Tamamlandı', 0, 0, 0, 'QA7-sayfa' " +
        "FROM generate_series(1, $missing) AS g;") | Out-Null
}
$total = Count-Service 'SELECT count(*) FROM reconciliation_runs;'
$dbOrder = @(Get-ServiceRows 'SELECT id FROM reconciliation_runs ORDER BY id DESC;')
Show-ServiceQuery 'SELECT count(*) AS calisma, max(id) AS en_yeni, min(id) AS en_eski FROM reconciliation_runs;'

Write-DbHeader 'Fatura Servisi' "A) $total çalışma, 50'lik sayfalarla"
$pages = [math]::Ceiling($total / 50)
$read = @(); $totals = @(); $sizes = @()
for ($page = 1; $page -le $pages; $page++) {
    $r = Get-Api "/api/v1/reconciliation-runs?page=$page&pageSize=50"
    $ids = @($r.Json.items | ForEach-Object { [string]$_.id })
    Write-Host ("  sayfa {0}: {1} çalışma ({2} .. {3}); totalCount {4}, totalPages {5}" -f $page, $ids.Count, $ids[0], $ids[-1], $r.Json.totalCount, $r.Json.totalPages)
    $read += $ids; $totals += $r.Json.totalCount; $sizes += $ids.Count
}
Check (Write-DbVerdict "en az 120 çalışma; her sayfada totalCount $total, totalPages $pages" "$total; totalCount: $(($totals | Select-Object -Unique) -join ', ')" `
    ($total -ge 120 -and @($totals | Select-Object -Unique).Count -eq 1 -and $totals[0] -eq $total))
$lastSize = $total - ($pages - 1) * 50
Check (Write-DbVerdict "sayfa boyutları: $((1..$pages | ForEach-Object { if ($_ -lt $pages) { 50 } else { $lastSize } }) -join ', ')" "$($sizes -join ', ')" `
    (($sizes -join ',') -eq ((1..$pages | ForEach-Object { if ($_ -lt $pages) { 50 } else { $lastSize } }) -join ',')))
$unique = @($read | Select-Object -Unique).Count
Check (Write-DbVerdict "okunan $total çalışma, tekrar yok, sıra veritabanıyla aynı (id azalan)" "okunan $($read.Count), farklı $unique, sıra $(if (($read -join ',') -eq ($dbOrder -join ',')) { 'aynı' } else { 'farklı' })" `
    ($read.Count -eq $total -and $unique -eq $total -and ($read -join ',') -eq ($dbOrder -join ',')))

Write-DbHeader 'Fatura Servisi' 'B) Sınırlar'
$p51 = Get-Api '/api/v1/reconciliation-runs?pageSize=51'
$p0 = Get-Api '/api/v1/reconciliation-runs?pageSize=0'
$page0 = Get-Api '/api/v1/reconciliation-runs?page=0'
$default = Get-Api '/api/v1/reconciliation-runs'
$beyond = Get-Api "/api/v1/reconciliation-runs?page=$($pages + 1)&pageSize=50"
Check (Write-DbVerdict 'pageSize=51: 400; pageSize=0: 400; page=0: 400' "$($p51.Status); $($p0.Status); $($page0.Status)" `
    ($p51.Status -eq 400 -and $p0.Status -eq 400 -and $page0.Status -eq 400))
Check (Write-DbVerdict 'parametresiz: sayfa 1, 20 çalışma' "sayfa $($default.Json.page), $(@($default.Json.items).Count) çalışma" `
    ($default.Json.page -eq 1 -and @($default.Json.items).Count -eq 20))
Check (Write-DbVerdict "sayfa $($pages + 1): 200, boş" "HTTP $($beyond.Status), $(@($beyond.Json.items).Count) çalışma" ($beyond.Status -eq 200 -and @($beyond.Json.items).Count -eq 0))

Write-Host ''
Write-Host 'Ekranda: http://localhost:5100/mutabakat - listenin altında Önceki / Sonraki, "N çalışma".'
Write-Result $allPassed 'Adım 5'
