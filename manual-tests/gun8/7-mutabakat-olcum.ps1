# Kontrol listesi 5: yük bittikten sonra mutabakat çalıştırılır; ne kadar sürdüğü ve servisin ne kadar bellek kullandığı
# ölçülür, takılı fatura kalmadığı gösterilir.
#
# Kuyruk boşalmış olmalı (6-yuk-olcum.ps1'den sonra). Mutabakat elle başlatılır (POST /api/v1/reconciliation-runs);
# çalışırken servis container'ının belleği docker stats ile alınabildiği sıklıkta (~1-2 sn) okunur. Süre çalışmanın
# kendi started_at / finished_at'inden. Takılı fatura: Gönderildi ya da İşleme Alındı'da özetteki süreden
# (Reconciliation:StuckAfterMinutes) uzun kalanlar; çalışmadan önce ve sonra veritabanından ve özetten.
param([string]$Container = 'staj-tasks-invoice-service-1', [int]$TimeoutMinutes = 30)

. "$PSScriptRoot\_common.ps1"

Write-Title 'Yük sonrası mutabakat: süre, bellek, takılı fatura'

function Get-MemoryMiB {
    $usage = (docker stats --no-stream --format '{{.MemUsage}}' $Container 2>$null | Select-Object -First 1)
    if ($usage -match '^([\d.]+)\s*([KMG]i?B)') {
        $value = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
        switch -regex ($Matches[2]) { '^K' { $value / 1024 } '^M' { $value } '^G' { $value * 1024 } }
    }
}

$stuckMinutes = (Get-Api '/api/v1/invoices/summary').Json.stuckAfterMinutes
$stuckSql = Get-StuckSql $stuckMinutes 'count(*)'
$pending = [int]@(Get-ServiceRows "SELECT count(*) FROM erp_outbox WHERE status = 'Bekliyor';")[0]
if ($pending -gt 0) { throw "Kuyrukta $pending fatura var; mutabakat kuyruk boşaldıktan sonra ölçülmeli." }

# Kuyruğun son faturaları henüz takılı sayılmıyor olabilir: kesinleşmemiş ve StuckAfterMinutes'ı doldurmamış fatura kalmayana
# kadar beklenir, yoksa mutabakat onlara dokunmaz ve sonra takılı fatura görünür.
$youngSql = "SELECT count(*) FROM invoices WHERE status IN ('Gönderildi','İşleme Alındı') AND updated_at > now() - interval '$stuckMinutes minutes';"
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
while (($young = [int]@(Get-ServiceRows $youngSql)[0]) -gt 0 -and (Get-Date) -lt $deadline) {
    Write-Host "  $(Get-Date -Format 'HH:mm:ss') henüz $stuckMinutes dakikayı doldurmamış kesinleşmemiş fatura: $young; bekleniyor" -ForegroundColor DarkGray
    Start-Sleep -Seconds 15
}

Write-DbHeader 'Mutabakattan önce' "Takılı: Gönderildi / İşleme Alındı'da $stuckMinutes dakikadan uzun"
Show-ServiceQuery "SELECT status, count(*) FROM invoices GROUP BY 1 ORDER BY 1;"
$stuckBefore = [int]@(Get-ServiceRows "$stuckSql;")[0]
$summaryBefore = (Get-Api '/api/v1/invoices/summary').Json.stuckCount
$idle = Get-MemoryMiB
Write-Host ("  Takılı: veritabanı {0}, özet {1}; servis belleği (boşta) {2:N1} MiB" -f $stuckBefore, $summaryBefore, $idle)

Write-Step 'Mutabakat başlatılıyor, çalışırken bellek okunuyor'
$started = Start-Reconciliation
if ($started.Status -ne 202) { throw "Mutabakat başlamadı: HTTP $($started.Status) $($started.Body)" }
$samples = [Collections.Generic.List[double]]::new()
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
do {
    $m = Get-MemoryMiB
    if ($null -ne $m) { $samples.Add($m) }
    $detail = Get-RunDetail $started.RunId
} while ($detail.run.status -eq 'Çalışıyor' -and (Get-Date) -lt $deadline)
if ($detail.run.status -eq 'Çalışıyor') { throw "Çalışma $($started.RunId) $TimeoutMinutes dakikada bitmedi." }
$after = Get-MemoryMiB

$run = $detail.run
$seconds = ([datetimeoffset]$run.finishedAt - [datetimeoffset]$run.startedAt).TotalSeconds
$peak = ($samples | Measure-Object -Maximum).Maximum
Write-Host ("  Çalışma {0}: {1}, {2:N1} sn; kontrol edilen {3}, düzeltilen {4}, raporlanan {5}" -f `
    $run.id, $run.status, $seconds, $run.checkedCount, $run.fixedCount, $run.reportedCount)
Write-Host ("  Bellek: boşta {0:N1} MiB, çalışırken en çok {1:N1} MiB ({2} okuma), sonra {3:N1} MiB" -f $idle, $peak, $samples.Count, $after)

Write-DbHeader 'Mutabakattan sonra' "Çalışma $($run.id)"
Show-ServiceQuery ("SELECT id, status, to_char(started_at AT TIME ZONE 'UTC', 'HH24:MI:SS.MS') AS basladi, " +
    "to_char(finished_at AT TIME ZONE 'UTC', 'HH24:MI:SS.MS') AS bitti, checked_count, fixed_count, reported_count " +
    "FROM reconciliation_runs WHERE id = $($run.id);")
Show-ServiceQuery "SELECT finding_type, action, count(*) FROM reconciliation_findings WHERE run_id = $($run.id) GROUP BY 1, 2 ORDER BY 1, 2;"
Show-ServiceQuery "SELECT status, count(*) FROM invoices GROUP BY 1 ORDER BY 1;"
$stuckAfter = [int]@(Get-ServiceRows "$stuckSql;")[0]
$summaryAfter = (Get-Api '/api/v1/invoices/summary').Json.stuckCount

$checks = @(
    (Write-DbVerdict 'mutabakat tamamlandı' "$($run.status), $('{0:N1}' -f $seconds) sn" ($run.status -eq 'Tamamlandı')),
    (Write-DbVerdict 'mutabakattan sonra takılı fatura yok (veritabanı ve özet)' "veritabanı $stuckAfter, özet $summaryAfter (önce $stuckBefore)" `
        ($stuckAfter -eq 0 -and $summaryAfter -eq 0))
)
Write-Result (@($checks | Where-Object { -not $_ }).Count -eq 0) ("Mutabakat {0:N1} sn, servis belleği en çok {1:N1} MiB, takılı fatura 0" -f $seconds, $peak)
