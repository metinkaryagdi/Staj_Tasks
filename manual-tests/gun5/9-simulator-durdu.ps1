# Gün 5 - Kontrol listesi 9: mutabakat sırasında simülatör ulaşılamaz: çalışma Başarısız olarak kaydedilir, hiçbir fatura
# değişmez. Simülatör açıldıktan sonraki çalışma eksik kalanı düzeltir. ~3 dk.
#
# Simülatörü durdurmak yerine docker pause ile dondururuz: bağlantı kurulur ama cevap gelmez, servis Erp:TimeoutSeconds (10 sn)
# bekleyip vazgeçer. Çalışma bu sürede Çalışıyor durumundadır; yani simülatör çalışma sürerken cevap vermemektedir.
# 5 fatura oluşturulur, simülatör karar haberlerini hiç göndermez (LostDecisionRate %100) ve eşik 1 dk'ya indirilir.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: simülatör devam ettiriliyor, ayarlar varsayılana döndürülüyor." -ForegroundColor Red
       try { Invoke-Compose @('unpause', 'erp-simulator') } catch { }
       try { Restart-Simulator; Restart-InvoiceService } catch { }; break }

Write-Title 'Kontrol listesi 9) Mutabakat sürerken simülatör ulaşılamaz: Başarısız, hiçbir fatura değişmiyor'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
Restart-Simulator (Get-SimSettings -Problems @{ LostDecisionRate = 100 })
Restart-InvoiceService @{ Reconciliation__StuckAfterMinutes = 1 }

$numbers = @(New-Invoices 5)
$list = InList $numbers
Wait-InvoicesIn $numbers @('Gönderildi', 'İşleme Alındı') 60 'gönderilmiş' | Out-Null
Wait-EventsDone $numbers | Out-Null

Write-Step 'Faturaların 1 dk''dan uzun süredir aynı durumda kalması ve karar zamanlarının gelmesi bekleniyor'
$watch = [Diagnostics.Stopwatch]::StartNew()
while ((Count-Service "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND updated_at > now() - interval '70 seconds';") -gt 0 -and $watch.Elapsed.TotalSeconds -lt 150) {
    Start-Sleep -Seconds 5
}
Write-Host ('  {0:N0} sn beklendi.' -f $watch.Elapsed.TotalSeconds)

$snapshot = "SELECT invoice_number, status, coalesce(erp_reference, '-'), updated_at FROM invoices WHERE invoice_number IN ($list) ORDER BY invoice_number;"
Write-DbHeader 'Fatura Servisi' 'Mutabakattan önce: 5 fatura Gönderildi / İşleme Alındı''da kaldı (kararları ERP''de var, haberleri gelmedi)'
Show-ServiceQuery $snapshot
$before = @(Get-ServiceRows $snapshot) -join "`n"
Show-ErpQuery ("SELECT invoice_number, event_type, kind, status FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'LostDecision' ORDER BY 1;")

# --- Simülatör dondurulur, mutabakat başlatılır -----------------------------------------------------------------------------
Write-Step 'Simülatör donduruluyor (docker pause) ve mutabakat başlatılıyor'
Invoke-Compose @('pause', 'erp-simulator')
try {
    $started = Start-Reconciliation
    Write-Host "  POST -> HTTP $($started.Status), çalışma $($started.RunId)"
    $sawRunning = (Get-RunDetail $started.RunId).run.status -eq 'Çalışıyor'
    $failed = Wait-RunDone $started.RunId 60
    Write-Host "  çalışma $($started.RunId): $($failed.run.status) - $($failed.run.error)"
}
finally { Invoke-Compose @('unpause', 'erp-simulator') }

Write-DbHeader 'Fatura Servisi' 'Başarısız çalışma ve faturaların hâli'
Show-Run $started.RunId
Show-Findings $started.RunId
Show-ServiceQuery $snapshot
$afterFailed = @(Get-ServiceRows $snapshot) -join "`n"
$findingsOfFailed = Count-Service "SELECT count(*) FROM reconciliation_findings WHERE run_id = $($started.RunId);"

Check (Write-DbVerdict 'POST 202, çalışma Çalışıyor iken simülatör cevap vermiyor' "HTTP $($started.Status), Çalışıyor görüldü: $sawRunning" ($started.Status -eq 202 -and $sawRunning))
Check (Write-DbVerdict 'çalışma Başarısız, hata ERP''ye ulaşılamadığını söylüyor' "$($failed.run.status): $($failed.run.error)" `
    ($failed.run.status -eq 'Başarısız' -and $failed.run.error -like '*ERP*'))
Check (Write-DbVerdict 'hiçbir fatura değişmedi (durum, referans, updated_at aynı)' 'karşılaştırıldı' ($afterFailed -eq $before))
Check (Write-DbVerdict 'başarısız çalışmanın bulgusu yok' "$findingsOfFailed" ($findingsOfFailed -eq 0))

# --- Simülatör açıldı: sonraki çalışma düzeltir ----------------------------------------------------------------------------------
Write-Step 'Simülatör açıldı; mutabakat yeniden başlatılıyor'
Wait-Health $SimulatorUrl
$second = Invoke-Reconciliation
Write-Host "  çalışma $($second.run.id): $($second.run.status), düzeltilen $($second.run.fixedCount)"
Write-DbHeader 'Fatura Servisi' 'İkinci çalışma ve faturaların hâli'
Show-Run $second.run.id
Show-Findings $second.run.id "AND invoice_number IN ($list)"
Show-ServiceQuery "SELECT invoice_number, status, reject_reason, erp_reference FROM invoices WHERE invoice_number IN ($list) ORDER BY invoice_number;"
$fixedMine = Count-Service ("SELECT count(*) FROM reconciliation_findings WHERE run_id = $($second.run.id) AND finding_type = 'Takılı Fatura' " +
                            "AND action = 'Düzeltildi' AND invoice_number IN ($list);")
$stillStuck = Count-Service "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status IN ('Gönderildi', 'İşleme Alındı');"

Check (Write-DbVerdict 'ikinci çalışma Tamamlandı' $second.run.status ($second.run.status -eq 'Tamamlandı'))
Check (Write-DbVerdict '5 faturanın 5''i Takılı Fatura olarak düzeltildi' "$fixedMine" ($fixedMine -eq 5))
Check (Write-DbVerdict 'Gönderildi / İşleme Alındı''da kalan fatura 0' "$stillStuck" ($stillStuck -eq 0))

Restart-Simulator
Restart-InvoiceService
Write-Result $allPassed 'simülatör ulaşılamazken çalışma Başarısız, hiçbir fatura değişmedi; açılınca sonraki çalışma düzeltti'
