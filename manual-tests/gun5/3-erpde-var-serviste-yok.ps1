# Gün 5 - Kontrol listesi 3: simülatörün veritabanına servisin bilmediği bir fatura numarasıyla elle kayıt ekle.
# Mutabakat bunu "ERP'de var, serviste yok" olarak raporlar; iki tarafta hiçbir şey değişmez. ~1 dk.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: $_ - simülatör ve servis varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Restart-Simulator; Restart-InvoiceService } catch { }; break }

Write-Title 'Kontrol listesi 3) Simülatörde elle eklenen, serviste olmayan fatura: raporlanıyor'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
Restart-Simulator (Get-SimSettings -NoEvents)
Restart-InvoiceService

$number = "ELLE-$(Get-Date -Format 'yyyyMMddHHmmss')"
Write-Step "Simülatörün veritabanına elle kayıt ekleniyor: $number"
Invoke-Sql ("INSERT INTO invoices (invoice_number, customer_code, amount, currency, invoice_date, received_at, behavior, request_sequence) " +
            "VALUES ('$number', 'C-ELLE', 321.45, 'TRY', '2026-10-05', now(), 'Success', 0);") | Out-Null
Show-ErpQuery "SELECT invoice_number, erp_reference, customer_code, amount FROM invoices WHERE invoice_number = '$number';"
$erpBefore = (@(Get-ErpRows "SELECT erp_reference, customer_code, amount FROM invoices WHERE invoice_number = '$number';") -join ';')

Write-Step 'Mutabakat elle başlatılıyor (POST /api/v1/reconciliation-runs)'
$run = Invoke-Reconciliation
$id = $run.run.id
Write-Host "  çalışma ${id}: $($run.run.status)"

Write-DbHeader 'Fatura Servisi' 'Çalışma ve bu faturanın bulgusu'
Show-Run $id
Show-Findings $id "AND invoice_number = '$number'"
$finding = @(Get-ServiceRows "SELECT finding_type, action FROM reconciliation_findings WHERE run_id = $id AND invoice_number = '$number';")
$inService = Count-Service "SELECT count(*) FROM invoices WHERE invoice_number = '$number';"
$erpAfter = (@(Get-ErpRows "SELECT erp_reference, customer_code, amount FROM invoices WHERE invoice_number = '$number';") -join ';')

Check (Write-DbVerdict 'çalışma Tamamlandı' $run.run.status ($run.run.status -eq 'Tamamlandı'))
Check (Write-DbVerdict 'bulgu: Serviste Yok / Raporlandı' ($finding -join ', ') ($finding.Count -eq 1 -and $finding[0] -eq 'Serviste Yok|Raporlandı'))
Check (Write-DbVerdict 'serviste bu numarayla fatura yok (düzeltilmedi, eklenmedi)' "$inService" ($inService -eq 0))
Check (Write-DbVerdict 'simülatördeki kayıt değişmedi' $erpAfter ($erpAfter -eq $erpBefore))

# --- Endpoint ayrıntıları: Location başlığı, liste sırası, olmayan çalışma -----------------------------------------------
Write-Step 'Endpoint ayrıntıları: ikinci bir mutabakat başlatılıyor (Location), sonra liste ve olmayan çalışma'
$again = Start-Reconciliation
if ($again.Status -eq 202) { Wait-RunDone $again.RunId | Out-Null }
$listText = $script:Http.GetAsync("$ServiceUrl/api/v1/reconciliation-runs").GetAwaiter().GetResult().Content.ReadAsStringAsync().GetAwaiter().GetResult()
$ids = @(($listText | ConvertFrom-Json) | ForEach-Object { [long]$_.id })
$sortedIds = @($ids | Sort-Object -Descending)
$missing = $script:Http.GetAsync("$ServiceUrl/api/v1/reconciliation-runs/999999999").GetAwaiter().GetResult()
Check (Write-DbVerdict 'POST 202 ve Location = /api/v1/reconciliation-runs/{id}' "HTTP $($again.Status), $($again.Location)" `
    ($again.Status -eq 202 -and $again.Location -like "*/api/v1/reconciliation-runs/$($again.RunId)"))
Check (Write-DbVerdict 'liste en yeniden eskiye (id azalan); ilk eleman en son çalışma' "$($ids.Count) çalışma, ilk $($ids[0])" `
    ($ids.Count -ge 2 -and ($ids -join ',') -eq ($sortedIds -join ',') -and $ids[0] -eq $again.RunId))
Check (Write-DbVerdict 'olmayan çalışma 404' "HTTP $([int]$missing.StatusCode)" ([int]$missing.StatusCode -eq 404))

Restart-Simulator
Write-Result $allPassed 'ERP''de olup serviste olmayan fatura raporlandı, iki tarafta hiçbir şey değişmedi'
