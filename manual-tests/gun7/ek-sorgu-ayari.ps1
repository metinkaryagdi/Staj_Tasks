# Gün 7 - Ek: NotFoundRecheckHours ayarı canlıda: 24'ten 1 saate çekilince "Kayıt yok" faturası 1 saat sonra soruluyor. ~3 dk.
#
#   İki eski Başarısız fatura eklenir; "Kayıt yok" cevabı A'da 59 dk, B'de 61 dk önce alınmış. Ayar dosyasındaki değerle
#   (24 saat) ikisi de sorulmamalı. Servis NotFoundRecheckHours=1 ile yeniden başlatılınca B sorulmalı, A sorulmamalı; 75 sn
#   sonra A da sorulmalı. 1 saatlik ayarla, 1 saatten önce "yok" denmiş diğer eski faturalar da yeniden sorulur (log satırları
#   gösterilmez, özet satırında sayılır). Sonda servis ayar dosyasındaki değerlerle yeniden başlatılır.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: $_ - servis varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Restart-InvoiceService } catch { }; break }

Write-Title 'Ek) NotFoundRecheckHours ayarı canlıda: 24 -> 1 saat'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

function Run-And-Check([string]$Title, [bool]$ExpectA, [bool]$ExpectB) {
    $r = Invoke-Reconciliation
    Write-Host "  çalışma $($r.run.id): $($r.run.status)"
    $log = Get-RunLookups $r.run.id @($a, $b)
    $log | ForEach-Object { Write-Host "  log: $_" -ForegroundColor DarkGray }
    Show-ErpCheck @($a, $b)
    $askedA = @($log | Where-Object { $_ -match "invoice=$a answer=NotFound" }).Count -eq 1
    $askedB = @($log | Where-Object { $_ -match "invoice=$b answer=NotFound" }).Count -eq 1
    Write-DbHeader 'Fatura Servisi' $Title
    Check (Write-DbVerdict "A ($a) $(Get-AskedText $ExpectA)" (Get-AskedText $askedA) ($askedA -eq $ExpectA))
    Check (Write-DbVerdict "B ($b) $(Get-AskedText $ExpectB)" (Get-AskedText $askedB) ($askedB -eq $ExpectB))
}
function Get-AskedText([bool]$Asked) { if ($Asked) { 'soruldu' } else { 'sorulmadı' } }

Wait-Service
Write-Step 'İki Başarısız fatura ekleniyor (3 gün önce oluşturulmuş, cevap "Kayıt yok"): A 59 dk önce, B 61 dk önce sorulmuş'
$a = New-NotFoundInvoice 'QA7-AYAR' '59 minutes'
$b = New-NotFoundInvoice 'QA7-AYAR' '61 minutes'
Write-Host "  A: $a   B: $b"
Show-ErpCheck @($a, $b)

Write-Step '1) Ayar dosyasındaki değerle (24 saat) mutabakat'
Write-Host "  Serviste: $(Get-ServiceEnv 'Reconciliation__NotFoundRecheckHours')"
Run-And-Check '24 saat: ikisi de sorulmadı' $false $false

Restart-InvoiceService @{ Reconciliation__NotFoundRecheckHours = 1 }
Write-Host "  Serviste: $(Get-ServiceEnv 'Reconciliation__NotFoundRecheckHours')"
Write-Step '2) 1 saat ayarıyla mutabakat'
Run-And-Check '1 saat: B (61 dk) soruldu, A (59 dk) sorulmadı' $false $true

Write-Step '75 sn bekleniyor: A''nın sorusunun üzerinden 1 saat geçecek'
Start-Sleep -Seconds 75
Write-Step '3) 1 saat ayarıyla mutabakat'
Run-And-Check '1 saat doldu: A soruldu; B az önce sorulduğu için sorulmadı' $true $false

Restart-InvoiceService
Write-Host "  Serviste: $(Get-ServiceEnv 'Reconciliation__NotFoundRecheckHours')"
Write-Result $allPassed 'ayar 1 saate çekilince fatura 1 saat sonra yeniden soruldu; servis ayar dosyasındaki değere döndü'
