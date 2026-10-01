# Gün 4 (ERP'den Gelen Haberler) script'lerinin ortak yardımcıları. Gün 3'ün gun3\_common.ps1'ini de yükler
# (Gün 1 ve Gün 2 yardımcıları dahil). Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun3\_common.ps1"

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
    $text = Get-Content (Join-Path $RepoRoot 'invoice-service\src\InvoiceService\appsettings.json') -Raw -Encoding UTF8
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
