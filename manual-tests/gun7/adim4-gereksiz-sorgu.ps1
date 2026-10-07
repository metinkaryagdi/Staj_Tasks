# Gün 7 - Adım 4: ERP'nin hiç almadığı eski Başarısız faturalar 24 saat içinde yeniden sorulmuyor. ~1 dk.
#
#   50 Başarısız fatura veritabanına 3 gün önce oluşturulmuş olarak eklenir; ERP onları hiç görmedi (24 saatlik mutabakat
#   penceresinin dışındalar, ERP'ye tek tek sorulurlar). Mutabakat iki kez arka arkaya çalıştırılır:
#   1) ilk çalışma 50'sini ERP'ye sorar, cevap "yok"; erp_checked_at / erp_check_result yazılır, updated_at değişmez.
#   2) ikinci çalışma hiçbirini sormaz. Kanıt: servis logundaki "Reconciliation asked the ERP" satırları ve çalışma özeti.
#   3) Bunlardan biri değişince (updated_at ilerler; örn. yeniden gönderilip yine Başarısız olursa) bir sonraki çalışma
#      yalnızca onu sorar.
#
# Önce servisin yeni kodla derlenmiş olması gerekir: docker compose up -d --build invoice-service
# Eklenen 50 fatura kalır (müşteri kodu QA7-ESKI); ERP'de olmadıkları için hiçbir bulgu üretmezler.
. "$PSScriptRoot\_common.ps1"

Write-Title 'Adım 4) ERP''nin "yok" dediği eski Başarısız faturalar 24 saat yeniden sorulmuyor'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

# Bir çalışmanın servis logundaki ERP sorguları ve özet satırı.
function Get-RunLookups([long]$RunId) {
    $log = @(Get-ServiceLog)
    [pscustomobject]@{
        Asked   = @($log | Where-Object { $_ -match "Reconciliation asked the ERP run=$RunId " })
        Summary = @($log | Where-Object { $_ -match "Reconciliation ERP lookups run=$RunId " }) | Select-Object -Last 1
    }
}

Wait-Service

Write-Step 'Önce bir çalışma: daha önce var olan eski faturaların cevabı da kaydedilsin, aşağıdaki sayılar yalnızca yeni 50 faturayı göstersin'
$settle = Invoke-Reconciliation
Write-Host "  çalışma $($settle.run.id): $($settle.run.status)"

Write-Step "50 Başarısız fatura, 3 gün önce oluşturulmuş olarak ekleniyor (ERP'ye hiç gönderilmedi)"
$numbers = @(Get-ServiceRows ("INSERT INTO invoices (invoice_number, customer_code, amount, currency, invoice_date, status, last_error, send_attempt_count, created_at, updated_at) " +
    "SELECT 'FTR-' || lpad(nextval('invoice_number_seq')::text, 6, '0'), 'QA7-ESKI', 100.00, 'TRY', current_date - 3, 'Başarısız', " +
    "'elle eklendi: ERP hiç almadı', 10, now() - interval '3 days', now() - interval '3 days' FROM generate_series(1, 50) RETURNING invoice_number;") |
    Where-Object { $_ -match '^FTR-' })
$list = InList $numbers
Write-Host "  $($numbers.Count) fatura: $($numbers[0]) .. $($numbers[-1])"
Show-ServiceQuery "SELECT count(*), min(created_at), count(erp_checked_at) AS sorulmus FROM invoices WHERE invoice_number IN ($list);"
$inErp = Count-Erp "SELECT count(*) FROM invoices WHERE invoice_number IN ($list);"
Check (Write-DbVerdict "50 fatura serviste Başarısız, ERP'de 0 kayıt" "$($numbers.Count) fatura, ERP'de $inErp" ($numbers.Count -eq 50 -and $inErp -eq 0))

# --- 1) İlk çalışma ------------------------------------------------------------------------------------------------
$first = Invoke-Reconciliation
$r1 = Get-RunLookups $first.run.id
$ours1 = @($r1.Asked | Where-Object { $_ -match 'invoice=(FTR-\d+)' -and $numbers -contains $Matches[1] })
Write-DbHeader 'Fatura Servisi' "1) Çalışma $($first.run.id): 50 faturanın her biri ERP'ye bir kez soruluyor"
Write-Host '  Servis logu (ilk 3 ve son satır):'
$ours1 | Select-Object -First 3 | ForEach-Object { Write-Host "    $_" }
Write-Host "    ..."
Write-Host "    $($ours1[-1])"
Write-Host "    $($r1.Summary)"
Check (Write-DbVerdict '50 sorgu, hepsinin cevabı NotFound' "$($ours1.Count) sorgu, NotFound: $(@($ours1 | Where-Object { $_ -match 'answer=NotFound' }).Count)" `
    ($ours1.Count -eq 50 -and @($ours1 | Where-Object { $_ -match 'answer=NotFound' }).Count -eq 50))
Show-ServiceQuery "SELECT erp_check_result, count(*), min(erp_checked_at) AS ilk, max(erp_checked_at) AS son, count(*) FILTER (WHERE updated_at < now() - interval '2 days') AS updated_at_degismedi FROM invoices WHERE invoice_number IN ($list) GROUP BY 1;"
$recorded = Count-Service "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND erp_check_result = 'Kayıt yok' AND erp_checked_at > now() - interval '5 minutes' AND updated_at < now() - interval '2 days';"
Check (Write-DbVerdict "50 faturada erp_check_result = 'Kayıt yok', erp_checked_at az önce, updated_at 3 gün önce kaldı" "$recorded" ($recorded -eq 50))
$findings = Count-Service "SELECT count(*) FROM reconciliation_findings WHERE run_id = $($first.run.id) AND invoice_number IN ($list);"
Check (Write-DbVerdict 'bu faturalar için bulgu yok (ERP almadı, serviste de Başarısız)' "$findings" ($findings -eq 0))

# --- 2) İkinci çalışma ---------------------------------------------------------------------------------------------
$second = Invoke-Reconciliation
$r2 = Get-RunLookups $second.run.id
$ours2 = @($r2.Asked | Where-Object { $_ -match 'invoice=(FTR-\d+)' -and $numbers -contains $Matches[1] })
Write-DbHeader 'Fatura Servisi' "2) Çalışma $($second.run.id), hemen ardından: hiçbiri sorulmuyor"
Write-Host "    $($r2.Summary)"
$skipped = if ($r2.Summary -match 'skippedRecentlyNotFound=(\d+)') { [int]$Matches[1] } else { -1 }
Check (Write-DbVerdict "bu 50 fatura için 0 sorgu; özet: en az 50 atlandı" "$($ours2.Count) sorgu; atlanan $skipped" ($ours2.Count -eq 0 -and $skipped -ge 50))

# --- 3) Değişen fatura yeniden soruluyor ---------------------------------------------------------------------------
$changed = $numbers[0]
Invoke-ServiceSql "UPDATE invoices SET updated_at = now() WHERE invoice_number = '$changed';" | Out-Null
$third = Invoke-Reconciliation
$r3 = Get-RunLookups $third.run.id
$ours3 = @($r3.Asked | Where-Object { $_ -match 'invoice=(FTR-\d+)' -and $numbers -contains $Matches[1] } | ForEach-Object { if ($_ -match 'invoice=(FTR-\d+)') { $Matches[1] } })
Write-DbHeader 'Fatura Servisi' "3) $changed değişti (updated_at = şimdi), çalışma $($third.run.id)"
Write-Host "    $($r3.Summary)"
Check (Write-DbVerdict "yalnızca $changed soruluyor" "$($ours3 -join ', ')" ($ours3.Count -eq 1 -and $ours3[0] -eq $changed))

Write-Host ''
Write-Host "Ekranda: http://localhost:5100/faturalar/$changed - Mutabakatın ERP'ye son sorusu ve cevabı."
Write-Result $allPassed 'Adım 4'
