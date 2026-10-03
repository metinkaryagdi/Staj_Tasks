# Gün 4 (ERP'den Gelen Haberler) script'lerinin ortak yardımcıları. Gün 3'ün gun3\_common.ps1'ini de yükler
# (Gün 1 ve Gün 2 yardımcıları dahil). Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun3\_common.ps1" -WithWebhooks

# Verilen JSON gövdesini POST eder; HTTP kodunu ve gövdeyi döner.
function Send-Json([string]$Url, [string]$Json) {
    $content = New-Object System.Net.Http.StringContent($Json, [Text.Encoding]::UTF8, 'application/json')
    $response = $script:Http.PostAsync($Url, $content).GetAwaiter().GetResult()
    [pscustomobject]@{
        Status = [int]$response.StatusCode
        Body   = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
}

# --- ERP haberleri (webhook) ----------------------------------------------------------------------------------------

# Servisin ayar dosyasındaki gizli anahtar (appsettings.json yorum içerdiği için ConvertFrom-Json yerine regex).
function Get-WebhookSecret {
    $text = Get-Content (Join-Path $RepoRoot 'invoice-service\src\InvoiceService.Api\appsettings.json') -Raw -Encoding UTF8
    if ($text -notmatch '"ErpWebhooks"[\s\S]*?"Secret"\s*:\s*"([^"]+)"') { throw 'ErpWebhooks:Secret ayar dosyasında bulunamadı.' }
    $Matches[1]
}

function Get-UnixNow { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# HMAC-SHA256(secret, "{timestamp}.{gövde}") -> küçük harfli hex. Servisin beklediği biçim.
function Get-WebhookSignature([string]$Secret, [string]$Timestamp, [byte[]]$Body) {
    $hmac = New-Object System.Security.Cryptography.HMACSHA256 (,[Text.Encoding]::UTF8.GetBytes($Secret))
    try {
        $signed = [Text.Encoding]::UTF8.GetBytes("$Timestamp.") + $Body
        -join ($hmac.ComputeHash([byte[]]$signed) | ForEach-Object { $_.ToString('x2') })
    }
    finally { $hmac.Dispose() }
}

# Bir ERP haberinin JSON gövdesi (alan sırası sabit; imza bu baytlar üzerinden).
function New-WebhookBody([string]$EventId, [string]$Type, [string]$Invoice, [string]$Reference, [string]$Reason) {
    $occurred = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $json = '{"event_id":"' + $EventId + '","event_type":"' + $Type + '","invoice_number":"' + $Invoice +
            '","erp_reference":"' + $Reference + '","occurred_at":"' + $occurred + '"'
    if ($Reason) { $json += ',"reason":"' + $Reason + '"' }
    $json + '}'
}

# POST /api/v1/erp-webhooks. $Timestamp / $Signature $null ise o başlık gönderilmez.
# Parametreler bilerek tipsiz: [string] $null'u boş metne çevirir, başlık "boş" gönderilirdi.
function Send-Webhook([byte[]]$Body, $Timestamp, $Signature) {
    $request = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post, "$ServiceUrl/api/v1/erp-webhooks")
    $request.Content = New-Object System.Net.Http.ByteArrayContent (,$Body)
    $request.Content.Headers.ContentType = 'application/json'
    if ($null -ne $Timestamp) { [void]$request.Headers.TryAddWithoutValidation('X-Erp-Timestamp', $Timestamp) }
    if ($null -ne $Signature) { [void]$request.Headers.TryAddWithoutValidation('X-Erp-Signature', $Signature) }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $response = $script:Http.SendAsync($request).GetAwaiter().GetResult()
    $watch.Stop()
    [pscustomobject]@{
        Status = [int]$response.StatusCode
        Body   = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        Ms     = $watch.ElapsedMilliseconds
    }
}

# Servis logundaki "ERP webhook ..." satırları; $Since (UTC) verilirse yalnızca ondan sonrakiler.
function Get-WebhookLog($Since) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    Get-ServiceLog | Where-Object { $_ -match '^(\S+ \S+) \w+: .*ERP webhook' } | Where-Object {
        -not $Since -or [datetime]::ParseExact(($_ -split ' ')[0..1] -join ' ', 'yyyy-MM-dd HH:mm:ss.fff', $inv) -ge $Since
    }
}

# --- Kontrol listesi yardımcıları -------------------------------------------------------------------------------------

function InList([string[]]$Values) { ($Values | ForEach-Object { "'$_'" }) -join ',' }

# Simülatör ayarları: POST davranışı Success %100 (ya da $Behavior %100), haber sorunlarının hepsi 0; $Problems ile tek tek açılır.
function Get-SimSettings([string]$Behavior = 'Success', [hashtable]$Problems = @{}, [switch]$NoEvents) {
    $s = @{ Simulator__Rates__Success = 0; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0
            Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0
            Webhooks__Problems__DuplicateRate = 0; Webhooks__Problems__OrderMixRate = 0; Webhooks__Problems__LostDecisionRate = 0
            Webhooks__Problems__FakeRate = 0; Webhooks__Problems__ReplayRate = 0 }
    $s["Simulator__Rates__$Behavior"] = 100
    foreach ($k in $Problems.Keys) { $s["Webhooks__Problems__$k"] = $Problems[$k] }
    if ($NoEvents) { $s['Webhooks__Enabled'] = 'false' }
    $s
}

# $Count fatura oluşturur (hepsi 202), numaralarını döner.
function New-Invoices([int]$Count) {
    $numbers = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $r = New-ServiceInvoice
        if ($r.HttpStatus -ne 202) { throw "Fatura 202 almadı: $($r.HttpStatus) $($r.Body)" }
        $numbers += $r.InvoiceNumber
    }
    Write-Host "  $Count fatura oluşturuldu: $($numbers[0]) .. $($numbers[-1])"
    $numbers
}

# Faturaların hepsi en az $Statuses'tan birinde olana kadar bekler; geçen saniyeyi döner.
function Wait-InvoicesIn([string[]]$Numbers, [string[]]$Statuses, [int]$TimeoutSeconds = 300, [string]$What = 'istenen durumda') {
    $list = InList $Numbers
    $in = InList $Statuses
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $last = -1
    while ($true) {
        $open = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE invoice_number IN ($list) AND status NOT IN ($in);")[0]
        if ($open -eq 0) { return [math]::Round($watch.Elapsed.TotalSeconds, 1) }
        if ($open -ne $last) { Write-Host ('  {0,5:N0} sn: {1} fatura henüz {2} değil' -f $watch.Elapsed.TotalSeconds, $open, $What) -ForegroundColor DarkGray }
        $last = $open
        if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw "$TimeoutSeconds sn içinde $open fatura $What olmadı." }
        Start-Sleep -Seconds 1
    }
}

# Simülatörde bu faturaların gönderilmeyi bekleyen (Pending / Waiting) haberi kalmayana kadar bekler.
function Wait-EventsDone([string[]]$Numbers, [int]$TimeoutSeconds = 300) {
    $list = InList $Numbers
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $last = -1
    while ($true) {
        $pending = [int]@(Get-ErpRows "SELECT count(*) FROM webhook_deliveries WHERE invoice_number IN ($list) AND status IN ('Pending', 'Waiting');")[0]
        if ($pending -eq 0) { Start-Sleep -Milliseconds 500; return [math]::Round($watch.Elapsed.TotalSeconds, 1) }
        if ($pending -ne $last) { Write-Host ('  {0,5:N0} sn: simülatörde {1} haber gönderilmeyi bekliyor' -f $watch.Elapsed.TotalSeconds, $pending) -ForegroundColor DarkGray }
        $last = $pending
        if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw "$TimeoutSeconds sn içinde $pending haber gönderilmedi." }
        Start-Sleep -Seconds 1
    }
}

function Count-Service([string]$Sql) { [int]@(Get-ServiceRows $Sql)[0] }
function Count-Erp([string]$Sql) { [int]@(Get-ErpRows $Sql)[0] }

# Servis logundaki durum değişimlerinden geriye gidenleri bulur (invoiceStatus=A->B, B A'dan geride ya da kesin durum değişmiş).
function Get-BackwardTransitions([string[]]$Numbers, $Since) {
    $rank = @{ 'Bekliyor' = 0; 'Başarısız' = 0; 'Gönderildi' = 1; 'İşleme Alındı' = 2; 'Onaylandı' = 3; 'Reddedildi' = 3 }
    $set = @{}; foreach ($n in $Numbers) { $set[$n] = $true }
    $checked = 0
    $backward = @()
    foreach ($line in Get-WebhookLog $Since) {
        if ($line -notmatch ' invoice=(\S+) .*invoiceStatus=(.+?)->(.+?) ignoreReason=') { continue }
        if (-not $set.ContainsKey($Matches[1])) { continue }
        $checked++
        $a = $Matches[2]; $b = $Matches[3]
        if ($rank[$b] -lt $rank[$a] -or ($rank[$a] -eq 3 -and $a -ne $b)) { $backward += $line }
    }
    [pscustomobject]@{ Checked = $checked; Backward = $backward }
}
