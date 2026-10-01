# Gün 3 - Ek test 1 (QA bulguları F2 ve F3): son (10.) deneme. Kontrol listesinin parçası değil. ~11 dk.
#
#   A) F3 - 10. deneme "kaydettim ama hata verdim"e denk geliyor. Fatura 9 kez ServerError alır (simülatör kaydetmez),
#      9. denemeden sonraki ~59 sn'lik beklemede simülatör SaveThenError %100'e alınır: 10. denemede simülatör faturayı
#      kaydedip 500 döner. Fatura simülatörde olduğuna göre serviste Gönderildi olmalı (simülatördeki referansla),
#      simülatöre 10'dan fazla POST gitmemeli, simülatörde tek kayıt olmalı.
#      Düzeltmeden önce: haklar bittiği için fatura Başarısız kalıyordu, ama simülatörde kayıtlıydı.
#   B) F2 - servis tam 10. denemedeyken öldürülüyor. Fatura yine 9 kez ServerError alır, sonra simülatör LateResponse
#      %100'e alınır (isteği alınca kaydeder, 30 sn cevap vermez). 10. deneme başlayınca servis docker kill ile
#      öldürülüp yeniden başlatılır. Kilit (60 sn) dolunca kayıt yeniden alınır. Deneme sayısı 10'u geçmemeli, yeni POST
#      yapılmamalı; fatura simülatörde olduğu için Gönderildi olmalı.
#      Düzeltmeden önce: kayıt 11. kez deneniyordu (attempt=11/10).
. "$PSScriptRoot\_common.ps1"

Write-Title 'Ek 1) Son deneme: kaydedip hata veren 10. deneme (F3) ve 10. denemede öldürülen servis (F2)'

$only = @{ Simulator__Rates__Success = 0; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0
           Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0 }

function Wait-NinthAttemptDone([string]$Number) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $row = @(Get-ServiceRows "SELECT attempt_count, locked_until IS NULL FROM erp_outbox WHERE invoice_number = '$Number';")[0] -split '\|'
        if ([int]$row[0] -ge 9 -and $row[1] -eq 't') { return }
        if ($watch.Elapsed.TotalSeconds -gt 420) { throw "$Number 9. denemeyi 420 sn içinde bitirmedi." }
        Start-Sleep -Milliseconds 500
    }
}

# Simülatörün logu container yeniden oluşturulunca sıfırlanır. Simülatör 10. denemeden hemen önce yeniden başlatıldığı
# için bu sayı yalnızca 10. deneme ve sonrasındaki POST'ları gösterir: tam 1 olmalı (10. deneme), sonrasında POST yok.
function Get-PostCount([string]$Number) {
    @(Get-SimulatorLog | Where-Object { $_ -match "ERP request #\d+ invoice=$Number behavior=" }).Count
}

function Show-Final([string]$Title, [string]$Number) {
    Write-Step "Servis logu ($Number)"
    Get-ServiceLog | Where-Object { $_ -match "ERP send( start)? invoice=$Number " } |
        ForEach-Object { Write-Host ('  ' + ($_ -replace ' info: InvoiceService\.Outbox\.OutboxProcessor\[0\]', '' -replace ' erpReference=.*$', '')) }
    Write-DbHeader $Title "Fatura numarası: $Number"
    Show-ServiceQuery "SELECT invoice_number, status, erp_reference, send_attempt_count, last_error FROM invoices WHERE invoice_number = '$Number';"
    Show-ServiceQuery "SELECT invoice_number, status, attempt_count, processed_at, locked_until, last_error FROM erp_outbox WHERE invoice_number = '$Number';"
    Show-ErpQuery "SELECT id, invoice_number, erp_reference, behavior, received_at FROM invoices WHERE invoice_number = '$Number' ORDER BY id;"
}

function Get-State([string]$Number) {
    $s = @(Get-ServiceRows ("SELECT i.status, coalesce(i.erp_reference, '-'), i.send_attempt_count, o.status, o.attempt_count " +
        "FROM invoices i JOIN erp_outbox o USING (invoice_number) WHERE invoice_number = '$Number';"))[0] -split '\|'
    $refs = @(Get-ErpRows "SELECT erp_reference FROM invoices WHERE invoice_number = '$Number' ORDER BY id;")
    [pscustomobject]@{ Status = $s[0]; Reference = $s[1]; Tries = [int]$s[2]; OutboxStatus = $s[3]; Attempts = [int]$s[4]
                       ErpRefs = $refs; Posts = Get-PostCount $Number }
}

Wait-Service
$allPassed = $true

# --- A) F3 ---------------------------------------------------------------------------------------------------------
$settings = $only.Clone(); $settings.Simulator__Rates__ServerError = 100
Restart-Simulator $settings
Write-Step 'A) 1 fatura; 9 deneme ServerError ile tükenene kadar bekleniyor (~4 dk)'
$a = (New-ServiceInvoices 1).From
Wait-NinthAttemptDone $a
Write-Host "  $a 9. denemeyi bitirdi; 10. deneme ~59 sn sonra. Simülatör SaveThenError %100'e alınıyor."
$settings = $only.Clone(); $settings.Simulator__Rates__SaveThenError = 100
Restart-Simulator $settings
Wait-QueueDrained $a $a 120 | Out-Null

Show-Final 'A) 10. deneme SaveThenError' $a
$st = Get-State $a
Write-Host ''
$ok = Write-DbVerdict ('fatura Gönderildi, outbox Tamamlandı; referans simülatördekiyle aynı; simülatörde 1 kayıt; ' +
    'simülatör son kez başlatıldıktan sonra 1 POST (10. deneme; sonrasında yeniden gönderim yok); outbox en fazla 10 deneme') `
    ("fatura $($st.Status), outbox $($st.OutboxStatus); referans $($st.Reference) / $($st.ErpRefs -join ','); simülatörde $($st.ErpRefs.Count) kayıt; " +
     "$($st.Posts) POST; outbox $($st.Attempts) deneme") `
    ($st.Status -eq 'Gönderildi' -and $st.OutboxStatus -eq 'Tamamlandı' -and $st.ErpRefs.Count -eq 1 -and $st.ErpRefs[0] -eq $st.Reference -and
     $st.Posts -eq 1 -and $st.Attempts -le 10)
$allPassed = $allPassed -and $ok

# --- B) F2 ---------------------------------------------------------------------------------------------------------
$settings = $only.Clone(); $settings.Simulator__Rates__ServerError = 100
Restart-Simulator $settings
Write-Step 'B) 1 fatura; 9 deneme ServerError ile tükenene kadar bekleniyor (~4 dk)'
$b = (New-ServiceInvoices 1).From
Wait-NinthAttemptDone $b
Write-Host "  $b 9. denemeyi bitirdi. Simülatör LateResponse %100'e alınıyor (isteği kaydeder, 30 sn cevap vermez)."
$settings = $only.Clone(); $settings.Simulator__Rates__LateResponse = 100
Restart-Simulator $settings

Write-Step '10. denemenin başlaması bekleniyor'
$watch = [Diagnostics.Stopwatch]::StartNew()
while (-not (Get-ServiceLog | Where-Object { $_ -match "ERP send start invoice=$b attempt=10/" })) {
    if ($watch.Elapsed.TotalSeconds -gt 120) { throw "$b 10. denemeye 120 sn içinde başlamadı." }
    Start-Sleep -Milliseconds 250
}
Start-Sleep -Seconds 2
$erpBeforeKill = [int]@(Get-ErpRows "SELECT count(*) FROM invoices WHERE invoice_number = '$b';")[0]
Write-Step "docker kill: servis 10. denemenin ortasında öldürülüyor (simülatörde şu an $erpBeforeKill kayıt)"
Push-Location $RepoRoot
$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $id = (& docker compose ps -q invoice-service).Trim()
    & docker kill $id 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'docker kill başarısız oldu.' }
}
finally { $ErrorActionPreference = $previous; Pop-Location }
Invoke-Compose @('start', 'invoice-service')
Wait-Service
Write-Host '  Servis yeniden ayakta. Kilit (60 sn) dolunca kayıt yeniden alınacak.'
Wait-QueueDrained $b $b 180 | Out-Null

Show-Final 'B) 10. denemede öldürülen servis' $b
$st = Get-State $b
$over = @(Get-ServiceLog | Where-Object { $_ -match "ERP send( start)? invoice=$b attempt=1[1-9]/" }).Count
Write-Host ''
$ok = Write-DbVerdict ('outbox ve fatura en fazla 10 deneme, logda 11. deneme yok; simülatör son kez başlatıldıktan sonra 1 POST ' +
    '(öldürülme anındaki 10. deneme; yeniden başlatmadan sonra POST yok); fatura Gönderildi, ' +
    'simülatörde 1 kayıt, referanslar aynı') `
    ("outbox $($st.Attempts), fatura $($st.Tries) deneme; logda 10'dan büyük deneme $over satır; $($st.Posts) POST; fatura $($st.Status); " +
     "simülatörde $($st.ErpRefs.Count) kayıt; referans $($st.Reference) / $($st.ErpRefs -join ',')") `
    ($st.Attempts -le 10 -and $st.Tries -le 10 -and $over -eq 0 -and $st.Posts -eq 1 -and $st.Status -eq 'Gönderildi' -and
     $st.ErpRefs.Count -eq 1 -and $st.ErpRefs[0] -eq $st.Reference)
$allPassed = $allPassed -and $ok

Restart-Simulator
Write-Result $allPassed "A ($a): son deneme kaydedip hata verdiğinde fatura simülatördeki kayıtla uzlaşıyor; B ($b): 10. denemede öldürülünce 11. deneme yapılmıyor"
