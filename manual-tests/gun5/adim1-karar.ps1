# Gün 5 - Adım 1: ERP Simülatörü GET /api/v1/invoices/{faturaNumarası} faturanın kararını da döner. ~2 dk.
#
#   A) Tek fatura: ilk haber 5 sn sonra olduğu için ilk cevap "none"; sonra received, sonra approved ya da rejected
#      (geriye gitmez). Karar zamanı geldiğinde cevapta decision, reason (yalnızca rejected) ve decidedAt var.
#   B) 20 fatura, karar haberinin kaybolma oranı %30: haberi hiç gönderilmeyen faturalarda da karar görünür.
#      Servisin durumuyla karşılaştırılır: Onaylandı = approved, Reddedildi = rejected (aynı reason);
#      serviste Gönderildi / İşleme Alındı'da kalanlar tam olarak kararı kaybolanlardır.
#
# Önce uygulamaların yeni kodla derlenmiş olması gerekir: docker compose up -d --build
# Simülatörü yeniden başlatır; sonunda varsayılan ayarlarına döner.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: $_ - simülatör varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Restart-Simulator } catch { }; break }

Write-Title 'Adım 1) GET /api/v1/invoices/{n}: decision, reason, decidedAt'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

# Cevaptan karar alanlarını okur. decidedAt'i metin olarak alır: ConvertFrom-Json tarihi yerel saate çevirirdi.
function Get-Decision([string]$Number) {
    $r = Get-Invoice $Number
    if ($r.Status -ne 200) { return [pscustomobject]@{ Status = $r.Status; Kind = '-'; Reason = ''; DecidedAt = $null } }
    $json = $r.Body | ConvertFrom-Json
    $at = if ($r.Body -match '"decidedAt":"([^"]+)"') { [DateTimeOffset]::Parse($Matches[1]) } else { $null }
    [pscustomobject]@{ Status = 200; Kind = $json.decision; Reason = $json.reason; DecidedAt = $at }
}

Wait-Service

# --- A) Tek fatura: none -> received -> karar --------------------------------------------------------------------------
Write-Step 'A) Tek fatura, ilk haber 5 sn sonra: kararın zaman içindeki seyri'
$settings = Get-SimSettings
$settings['Webhooks__FirstEventMinSeconds'] = 5
$settings['Webhooks__FirstEventMaxSeconds'] = 5
Restart-Simulator $settings
$one = @(New-Invoices 1)
$number = $one[0]
$rank = @{ 'none' = 0; 'received' = 1; 'approved' = 2; 'rejected' = 2 }
$seen = @()
$watch = [Diagnostics.Stopwatch]::StartNew()
$final = $null
while ($watch.Elapsed.TotalSeconds -lt 60) {
    $d = Get-Decision $number
    if ($d.Status -eq 200 -and ($seen.Count -eq 0 -or $seen[-1] -ne $d.Kind)) {
        $seen += $d.Kind
        Write-Host ('  {0,5:N1} sn: decision={1} reason={2} decidedAt={3}' -f $watch.Elapsed.TotalSeconds, $d.Kind, $d.Reason, $d.DecidedAt)
    }
    if ($d.Kind -in 'approved', 'rejected') { $final = $d; break }
    Start-Sleep -Milliseconds 500
}
Write-DbHeader 'ERP Simülatörü' "Bu faturanın planlanan haberleri ve kararın zamanı ($number)"
Show-ErpQuery "SELECT event_type, kind, status, to_char(occurred_at, 'HH24:MI:SS.MS') AS oluştu FROM webhook_deliveries WHERE invoice_number = '$number' ORDER BY occurred_at;"
$monotone = $true
for ($i = 1; $i -lt $seen.Count; $i++) { if ($rank[$seen[$i]] -lt $rank[$seen[$i - 1]]) { $monotone = $false } }
Check (Write-DbVerdict 'ilk cevap none' ($seen -join ' -> ') ($seen.Count -gt 0 -and $seen[0] -eq 'none'))
Check (Write-DbVerdict 'geriye gitmeden bir karara ulaşır' ($seen -join ' -> ') ($monotone -and $null -ne $final))
if ($final) {
    $reasonOk = ($final.Kind -eq 'approved' -and -not $final.Reason) -or ($final.Kind -eq 'rejected' -and $final.Reason)
    Check (Write-DbVerdict 'decidedAt dolu, reason yalnızca rejected iken dolu' "decision=$($final.Kind) reason='$($final.Reason)' decidedAt=$($final.DecidedAt)" `
        ($null -ne $final.DecidedAt -and $reasonOk))
}
$missing = Get-Invoice 'YOK-FATURA-1'
Check (Write-DbVerdict 'bilinmeyen fatura numarası hâlâ 404' "$($missing.Status)" ($missing.Status -eq 404))

# --- B) Kaybolan karar haberleri ---------------------------------------------------------------------------------------
Write-Step 'B) 20 fatura, karar haberi kaybolma oranı %30: haberi gönderilmeyen faturada da karar görünüyor mu?'
Restart-Simulator (Get-SimSettings -Problems @{ LostDecisionRate = 30 })
$numbers = New-Invoices 20
$list = InList $numbers
Wait-InvoicesIn $numbers @('Gönderildi', 'İşleme Alındı', 'Onaylandı', 'Reddedildi') 60 'gönderilmiş' | Out-Null
Wait-EventsDone $numbers | Out-Null

# Karar zamanı en geç ilk haber (10 sn) + ikinci haber (20 sn) = 30 sn sonra; kaybolan karar da bu zamanda "olur".
$deadline = [DateTime]::UtcNow.AddSeconds(90)
do {
    $decisions = @{}
    foreach ($n in $numbers) { $decisions[$n] = Get-Decision $n }
    $open = @($numbers | Where-Object { $decisions[$_].Kind -notin 'approved', 'rejected' }).Count
    if ($open -gt 0) { Start-Sleep -Seconds 2 }
} while ($open -gt 0 -and [DateTime]::UtcNow -lt $deadline)

Write-DbHeader 'ERP Simülatörü' 'Kararın haberi: Delivered = gönderildi, Skipped (LostDecision) = hiç gönderilmedi'
Show-ErpQuery ("SELECT invoice_number, event_type, kind, status, to_char(occurred_at, 'HH24:MI:SS') AS karar_zamanı FROM webhook_deliveries " +
               "WHERE invoice_number IN ($list) AND kind IN ('Normal', 'LostDecision') AND event_type <> 'invoice.received' ORDER BY invoice_number;")
Write-DbHeader 'Fatura Servisi' 'Faturaların durumu (kararı haberle öğrenen Onaylandı / Reddedildi olur)'
Show-ServiceQuery "SELECT invoice_number, status, reject_reason FROM invoices WHERE invoice_number IN ($list) ORDER BY invoice_number;"

$service = @{}
foreach ($row in (Get-ServiceRows "SELECT invoice_number, status, coalesce(reject_reason, '') FROM invoices WHERE invoice_number IN ($list);")) {
    $p = $row -split '\|'
    $service[$p[0]] = @{ Status = $p[1]; Reason = $p[2] }
}
$lostRows = Get-ErpRows "SELECT invoice_number FROM webhook_deliveries WHERE invoice_number IN ($list) AND kind = 'LostDecision';"
$lost = @{}; foreach ($l in $lostRows) { $lost[$l] = $true }
$dbTimes = @{}
foreach ($row in (Get-ErpRows ("SELECT invoice_number, to_char(occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') FROM webhook_deliveries " +
                               "WHERE invoice_number IN ($list) AND kind IN ('Normal', 'LostDecision') AND event_type <> 'invoice.received';"))) {
    $p = $row -split '\|'; $dbTimes[$p[0]] = $p[1]
}

$table = foreach ($n in $numbers) {
    $d = $decisions[$n]
    [pscustomobject]@{
        Fatura = $n; Servis = $service[$n].Status; ERP_karar = $d.Kind; Sebep = $d.Reason
        Haberi_gönderilmedi = [bool]$lost[$n]
    }
}
$table | Format-Table -AutoSize | Out-Host

$withDecision = @($numbers | Where-Object { $decisions[$_].Kind -in 'approved', 'rejected' }).Count
$stuck = @($numbers | Where-Object { $service[$_].Status -in 'Gönderildi', 'İşleme Alındı' })
$stuckIsLost = @($stuck | Where-Object { $lost[$_] }).Count -eq $stuck.Count -and $stuck.Count -eq $lost.Count
$agree = @($numbers | Where-Object {
    $s = $service[$_].Status; $d = $decisions[$_]
    ($s -eq 'Onaylandı' -and $d.Kind -eq 'approved') -or
    ($s -eq 'Reddedildi' -and $d.Kind -eq 'rejected' -and $d.Reason -eq $service[$_].Reason)
}).Count
$timesOk = @($numbers | Where-Object { $decisions[$_].DecidedAt -and $decisions[$_].DecidedAt.UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss') -eq $dbTimes[$_] }).Count

Check (Write-DbVerdict '20 faturanın hepsinde karar görünüyor' "$withDecision" ($withDecision -eq 20))
Check (Write-DbVerdict 'serviste Gönderildi / İşleme Alındı kalanlar = haberi gönderilmeyenler' "kalan $($stuck.Count), haberi gönderilmeyen $($lost.Count)" `
    ($stuckIsLost -and $lost.Count -gt 0))
Check (Write-DbVerdict 'haberi ulaşan faturalarda servisin durumu ve sebebi ERP kararıyla aynı' "$agree / $(20 - $stuck.Count)" ($agree -eq (20 - $stuck.Count)))
Check (Write-DbVerdict 'decidedAt = veritabanındaki karar zamanı' "$timesOk / 20" ($timesOk -eq 20))

Restart-Simulator
Write-Result $allPassed 'karar, haberi hiç gönderilmemiş olsa da zamanı gelince görünüyor; servisin durumuyla uyumlu'
