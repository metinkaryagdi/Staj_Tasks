# Gün 4 - "HABER KABUL KURALLARI" 1-6'nın canlı kanıtı. ~2 dk. Haberleri bu script imzalayıp gönderir; simülatörün kendi
# haberleri araya girmesin diye faturalar Webhooks__Enabled=false ile oluşturulur. Sonda simülatör varsayılana döner.
#
#   K1) Yanlış imza, başlık yok, yalnızca zaman damgası, 301 sn eski, 301 sn ileri -> 401 ve kayıt yok; 299 sn eski geçerli -> 200.
#   K2) Aynı event_id iki kez -> 200 / 200, ikincisi işlenmez (delivery_count 2, processed_at ve fatura değişmez).
#   K3) erp_reference farklı -> Yok Sayıldı (Referans Farklı) + warn log, fatura değişmez.
#   K4) Durumu geri götüren haber (karardan sonra received) -> Yok Sayıldı (Geri Götürüyor), fatura ve updated_at değişmez.
#   K5) Fatura Gönderildi olmadan gelen haber -> Bekliyor; fatura Gönderildi olunca aynı transaction'da işlenir.
#   K6) Her cevap 5 sn'den kısa: bu script'in bütün istekleri + 4 x 50 paralel istek.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: $_ - simülatör varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Restart-Simulator } catch { }; break }

$log = Join-Path $OutputDir ("gun4-ek-kabul-kurallari-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -Path $log | Out-Null
Write-Title 'HABER KABUL KURALLARI 1-6: canlı kanıt'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }
$secret = Get-WebhookSecret
$prefix = "kabul-$(Get-Date -Format 'HHmmss')-"
$since = [datetime]::UtcNow.AddSeconds(-1)
$latencies = New-Object System.Collections.Generic.List[long]

function Post([string]$Id, [string]$Type, [string]$Invoice, [string]$Ref, [string]$Reason, [long]$TsOffset = 0, [string]$Mode = 'ok') {
    $body = [Text.Encoding]::UTF8.GetBytes((New-WebhookBody "$prefix$Id" $Type $Invoice $Ref $Reason))
    $ts = "$((Get-UnixNow) + $TsOffset)"
    $r = switch ($Mode) {
        'ok'       { Send-Webhook $body $ts (Get-WebhookSignature $secret $ts $body) }
        'badsig'   { Send-Webhook $body $ts (Get-WebhookSignature 'baska-bir-anahtar-baska-bir-anahtar-baska' $ts $body) }
        'noheader' { Send-Webhook $body $null $null }
        'tsonly'   { Send-Webhook $body $ts $null }
    }
    $script:latencies.Add($r.Ms)
    $st = if ($r.Body -match '"status":"([^"]+)"') { $Matches[1] } else { '-' }
    Write-Host ('  {0,-6} {1,-17} {2,-10} {3,-9} -> HTTP {4} {5} ({6} ms)' -f $Id, $Type, $Invoice, $Mode, $r.Status, $st, $r.Ms)
    [pscustomobject]@{ Status = $r.Status; EventStatus = $st; Repeat = ($r.Body -match '"repeat":true') }
}
function Ev([string]$Id) { @(Get-ServiceRows "SELECT status || '|' || coalesce(ignore_reason,'-') || '|' || delivery_count || '|' || coalesce(to_char(processed_at,'HH24:MI:SS.US'),'-') FROM erp_webhook_events WHERE event_id = '$prefix$Id';")[0] }
function Inv([string]$N) { @(Get-ServiceRows "SELECT status || '|' || coalesce(erp_reference,'-') || '|' || to_char(updated_at,'HH24:MI:SS.US') FROM invoices WHERE invoice_number = '$N';")[0] }

Wait-Service
Restart-Simulator (Get-SimSettings -NoEvents)
$inv = New-Invoices 3
Wait-InvoicesIn $inv @('Gönderildi') 60 'Gönderildi' | Out-Null
$ref = @{}; foreach ($n in $inv) { $ref[$n] = @(Get-ServiceRows "SELECT erp_reference FROM invoices WHERE invoice_number = '$n';")[0] }
$a, $b, $c = $inv

# --- K1 ---------------------------------------------------------------------------------------------------------------
Write-Step 'K1) 401 ve kayıt yok; imza sabit zamanlı karşılaştırılıyor'
Write-Host '  Kod:' -ForegroundColor DarkGray
Select-String -Path (Join-Path $RepoRoot 'invoice-service\src\InvoiceService.Application\Webhooks\WebhookSignature.cs') -Pattern 'FixedTimeEquals|age > toleranceSeconds|age < -toleranceSeconds|MissingHeaders;' |
    ForEach-Object { Write-Host ("    WebhookSignature.cs:{0}: {1}" -f $_.LineNumber, $_.Line.Trim()) -ForegroundColor DarkGray }
$k1 = @(
    @{ Id = 'K1a'; Mode = 'badsig'; Off = 0; Exp = 401 }, @{ Id = 'K1b'; Mode = 'noheader'; Off = 0; Exp = 401 },
    @{ Id = 'K1c'; Mode = 'tsonly'; Off = 0; Exp = 401 }, @{ Id = 'K1d'; Mode = 'ok'; Off = -301; Exp = 401 },
    @{ Id = 'K1e'; Mode = 'ok'; Off = 301; Exp = 401 }, @{ Id = 'K1f'; Mode = 'ok'; Off = -299; Exp = 200 })
foreach ($k in $k1) {
    $r = Post $k.Id 'invoice.received' $a $ref[$a] $null $k.Off $k.Mode
    $stored = Count-Service "SELECT count(*) FROM erp_webhook_events WHERE event_id = '$prefix$($k.Id)';"
    $expStored = [int]($k.Exp -eq 200)
    Check (Write-DbVerdict "$($k.Id) ($($k.Mode), damga $($k.Off) sn): HTTP $($k.Exp), tabloda $expStored" "HTTP $($r.Status), tabloda $stored" ($r.Status -eq $k.Exp -and $stored -eq $expStored))
}

# --- K2 ---------------------------------------------------------------------------------------------------------------
Write-Step "K2) Aynı event_id iki kez ($b)"
$r1 = Post 'K2' 'invoice.received' $b $ref[$b]
$e1 = Ev 'K2'; $i1 = Inv $b
Start-Sleep -Milliseconds 1100
$r2 = Post 'K2' 'invoice.received' $b $ref[$b]
$e2 = Ev 'K2'; $i2 = Inv $b
Write-Host "  haber: $e1 -> $e2" -ForegroundColor DarkGray; Write-Host "  fatura: $i1 -> $i2" -ForegroundColor DarkGray
Check (Write-DbVerdict '200 / 200, ikincisi repeat=true; delivery_count 1 -> 2; processed_at ve fatura değişmedi' `
    "HTTP $($r1.Status)/$($r2.Status), repeat=$($r2.Repeat); $e1 -> $e2; fatura $i1 -> $i2" `
    ($r1.Status -eq 200 -and $r2.Status -eq 200 -and $r2.Repeat -and ($e1 -split '\|')[2] -eq '1' -and ($e2 -split '\|')[2] -eq '2' -and
     ($e1 -split '\|')[3] -eq ($e2 -split '\|')[3] -and $i1 -eq $i2))

# --- K3 ---------------------------------------------------------------------------------------------------------------
Write-Step "K3) erp_reference farklı ($c, faturadaki $($ref[$c]))"
$i1 = Inv $c
$r = Post 'K3' 'invoice.approved' $c 'ERP-BASKA-KAYIT'
Start-Sleep -Milliseconds 300
$i2 = Inv $c; $e = Ev 'K3'
$warn = @(Get-WebhookLog $since | Where-Object { $_ -match "warn: .*event=${prefix}K3 .*ignoreReason=Referans Farklı" })
$warn | ForEach-Object { Write-Host "  $($_.Substring(0, [Math]::Min(230, $_.Length)))" -ForegroundColor DarkGray }
Check (Write-DbVerdict 'Yok Sayıldı|Referans Farklı, warn log 1, fatura değişmedi' "$e; warn $($warn.Count); fatura $i1 -> $i2" `
    ($e -like 'Yok Sayıldı|Referans Farklı|*' -and $warn.Count -eq 1 -and $i1 -eq $i2))

# --- K4 ---------------------------------------------------------------------------------------------------------------
Write-Step "K4) Durumu geri götüren haber (${c}: önce karar, sonra received)"
$null = Post 'K4a' 'invoice.rejected' $c $ref[$c] 'Kabul kuralı testi'
$i1 = Inv $c
Start-Sleep -Milliseconds 1100
$r = Post 'K4b' 'invoice.received' $c $ref[$c]
$i2 = Inv $c; $e = Ev 'K4b'
Check (Write-DbVerdict 'karar sonrası received: Yok Sayıldı|Geri Götürüyor; fatura (durum, updated_at) değişmedi' "$e; fatura $i1 -> $i2" `
    ($e -like 'Yok Sayıldı|Geri Götürüyor|*' -and $i1 -eq $i2 -and $i1 -like 'Reddedildi|*'))

# --- K5 ---------------------------------------------------------------------------------------------------------------
Write-Step 'K5) Fatura Gönderildi olmadan gelen haber kaybolmuyor (simülatör LateResponse %100: servis 10 sn sonra vazgeçer)'
Restart-Simulator (Get-SimSettings -Behavior 'LateResponse' -NoEvents)
$late = @(New-Invoices 1)[0]
$watch = [Diagnostics.Stopwatch]::StartNew()
do { Start-Sleep -Milliseconds 100; $lateRef = @(Get-ErpRows "SELECT erp_reference FROM invoices WHERE invoice_number = '$late' ORDER BY id LIMIT 1;")[0]
     if ($watch.Elapsed.TotalSeconds -gt 20) { throw "$late simülatörde görünmedi." } } while (-not $lateRef)
$before = Inv $late
$null = Post 'K5a' 'invoice.received' $late $lateRef
$null = Post 'K5b' 'invoice.approved' $late $lateRef
$w1 = Ev 'K5a'; $w2 = Ev 'K5b'
Write-Host "  haber gelince fatura: $before; haberler: $w1 / $w2" -ForegroundColor DarkGray
Wait-InvoicesIn @($late) @('Onaylandı') 120 'Onaylandı' | Out-Null
Show-ServiceQuery ("SELECT e.event_id, e.status, to_char(e.received_at,'HH24:MI:SS.MS') geldi, to_char(e.processed_at,'HH24:MI:SS.MS') islendi, " +
    "to_char(o.processed_at,'HH24:MI:SS.MS') fatura_gonderildi FROM erp_webhook_events e JOIN erp_outbox o USING (invoice_number) " +
    "WHERE e.event_id LIKE '${prefix}K5%' ORDER BY e.received_at;")
$k5 = @(Get-ServiceRows ("SELECT count(*) FROM erp_webhook_events e JOIN erp_outbox o USING (invoice_number) WHERE e.event_id LIKE '${prefix}K5%' " +
    "AND e.status = 'İşlendi' AND e.received_at < o.processed_at AND e.processed_at >= o.processed_at AND e.processed_at - o.processed_at < interval '1 second';"))[0]
Check (Write-DbVerdict 'iki haber fatura Bekliyor iken Bekliyor kaydedildi; fatura Gönderildi olunca (aynı saniye içinde) işlendi; fatura Onaylandı' `
    "fatura $(( $before -split '\|')[0]); $(( $w1 -split '\|')[0]) / $(( $w2 -split '\|')[0]); kurala uyan $k5/2; son durum $(( (Inv $late) -split '\|')[0])" `
    (($before -split '\|')[0] -eq 'Bekliyor' -and ($w1 -split '\|')[0] -eq 'Bekliyor' -and ($w2 -split '\|')[0] -eq 'Bekliyor' -and $k5 -eq '2'))

# --- K6 ---------------------------------------------------------------------------------------------------------------
Write-Step 'K6) 5 sn içinde cevap: bu script''in istekleri + 4 x 50 paralel istek'
$single = ($latencies | Measure-Object -Maximum).Maximum
$worst = 0
for ($batch = 1; $batch -le 4; $batch++) {
    $tasks = @()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt 50; $i++) {
        $body = [Text.Encoding]::UTF8.GetBytes((New-WebhookBody "${prefix}K6-$batch-$i" 'invoice.received' $a $ref[$a]))
        $ts = "$(Get-UnixNow)"
        $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post, "$ServiceUrl/api/v1/erp-webhooks")
        $req.Content = New-Object System.Net.Http.ByteArrayContent (,$body)
        $req.Content.Headers.ContentType = 'application/json'
        [void]$req.Headers.TryAddWithoutValidation('X-Erp-Timestamp', $ts)
        [void]$req.Headers.TryAddWithoutValidation('X-Erp-Signature', (Get-WebhookSignature $secret $ts $body))
        $tasks += $script:Http.SendAsync($req)
    }
    [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks)
    $sw.Stop()
    $codes = @($tasks | ForEach-Object { [int]$_.Result.StatusCode } | Sort-Object -Unique)
    Write-Host ("  parti {0}: 50 istek, hepsinin bitmesi {1} ms, HTTP {2}" -f $batch, $sw.ElapsedMilliseconds, ($codes -join ','))
    if ($sw.ElapsedMilliseconds -gt $worst) { $worst = $sw.ElapsedMilliseconds }
}
Check (Write-DbVerdict 'tek tek isteklerin en yavaşı ve 50''lik paralel partilerin tamamı < 5000 ms' "tek istek en çok $single ms; 50 paralelin tamamı en çok $worst ms" ($single -lt 5000 -and $worst -lt 5000))

Restart-Simulator
Write-Result $allPassed 'kabul kuralları 1-6 canlı olarak doğrulandı'
Stop-Transcript | Out-Null
Write-Host "  Çıktı: $log" -ForegroundColor DarkGray
