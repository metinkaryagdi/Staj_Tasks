# Gün 6 (Operasyon Ekranı) script'lerinin ortak yardımcıları. Gün 5'in gun5\_common.ps1'ini de yükler
# (Gün 1-4 yardımcıları dahil). Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun5\_common.ps1"

# Fatura Servisi'ne GET atar; HTTP kodunu, gövdeyi ve (başarılıysa) çözümlenmiş JSON'u döner.
function Get-Api([string]$Path) {
    $response = $script:Http.GetAsync("$ServiceUrl$Path").GetAwaiter().GetResult()
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    [pscustomobject]@{
        Status = [int]$response.StatusCode; Body = $body
        Json = $(if ($response.IsSuccessStatusCode) { $body | ConvertFrom-Json } else { $null })
    }
}

# Tarayıcının yaptığı CORS ön isteği (OPTIONS): cevaptaki Access-Control-Allow-Origin değerini döner ('' = izin yok).
function Get-PreflightAllowOrigin([string]$Path, [string]$Origin, [string]$Method = 'POST') {
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Options, "$ServiceUrl$Path")
    $request.Headers.Add('Origin', $Origin)
    $request.Headers.Add('Access-Control-Request-Method', $Method)
    $response = $script:Http.SendAsync($request).GetAwaiter().GetResult()
    $values = $null
    if ($response.Headers.TryGetValues('Access-Control-Allow-Origin', [ref]$values)) { $values -join ',' } else { '' }
}

# Fatura Servisi'ne POST başlatır (bekletmeden): iki isteğin aynı anda gitmesi gereken testler için Task döner.
function Start-ApiPost([string]$Path, [string]$Json = $null) {
    $content = if ($null -ne $Json) { [Net.Http.StringContent]::new($Json, [Text.Encoding]::UTF8, 'application/json') } else { $null }
    $script:Http.PostAsync("$ServiceUrl$Path", $content)
}

# Start-ApiPost'un Task'ını bekler; Get-Api ile aynı biçimde döner (+ problem cevabındaki code alanı).
function Receive-Api($Task) {
    $response = $Task.GetAwaiter().GetResult()
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $json = $null
    try { if ($body) { $json = $body | ConvertFrom-Json } } catch { }
    [pscustomobject]@{ Status = [int]$response.StatusCode; Body = $body; Json = $json
                       Code = $(if ($json -and $json.PSObject.Properties['code']) { $json.code } else { '' }) }
}

function Post-Api([string]$Path, [string]$Json = $null) { Receive-Api (Start-ApiPost $Path $Json) }

# {"invoiceNumbers": [...]} gövdesi.
function ConvertTo-ResendBody([string[]]$Numbers) { (@{ invoiceNumbers = @($Numbers) } | ConvertTo-Json -Compress) }

# Zaman damgasını (API'den gelen metin ya da DateTime) saniye hassasiyetinde UTC metnine çevirir; veritabanıyla karşılaştırmak için.
function ConvertTo-UtcSeconds($Value) {
    if ($null -eq $Value -or $Value -eq '') { return '' }
    $utc = if ($Value -is [datetime]) { $Value.ToUniversalTime() }
           else { [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
    $utc.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
}

# SQL tarafında aynı biçim. (Çift tırnak kullanılmaz: PowerShell docker'a geçerken siler.)
function Get-SqlUtcSeconds([string]$Column) { "to_char($Column AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS')" }

# Özet sayılarını veritabanıyla karşılaştırmak için: faturalar sürekli değişiyorsa (takılı sayısı ayrıca zamanla da değişir:
# fatura 2 dakikayı geçince takılı olur) iki okuma arasında sayılar kayabilir. Veritabanı API'den önce ve sonra aynı çıkana kadar
# tekrar edilir; karşılaştırılan veritabanı değerleri de bu iki okumadan biridir, böylece gerçekten aynı ana denk gelir.
function Get-StableSummary([int]$Attempts = 30) {
    $statuses = @('Bekliyor', 'Gönderildi', 'İşleme Alındı', 'Onaylandı', 'Reddedildi', 'Başarısız')
    $countsSql = "SELECT status, count(*) FROM invoices GROUP BY status ORDER BY status;"
    for ($i = 0; $i -lt $Attempts; $i++) {
        $stuckMinutes = (Get-Api '/api/v1/invoices/summary').Json.stuckAfterMinutes
        $stuckSql = "SELECT count(*) FROM invoices WHERE status IN ('Gönderildi','İşleme Alındı') AND updated_at < now() - interval '$stuckMinutes minutes';"
        $countsBefore = @(Get-ServiceRows $countsSql); $stuckBefore = [int]@(Get-ServiceRows $stuckSql)[0]
        $api = Get-Api '/api/v1/invoices/summary'
        $countsAfter = @(Get-ServiceRows $countsSql); $stuckAfter = [int]@(Get-ServiceRows $stuckSql)[0]
        if (($countsBefore -join ';') -eq ($countsAfter -join ';') -and $stuckBefore -eq $stuckAfter) {
            $db = @{}
            foreach ($row in $countsAfter) { $p = $row -split '\|'; $db[$p[0]] = [int]$p[1] }
            return [pscustomobject]@{ Api = $api.Json; Db = $db; DbStuck = $stuckAfter; Statuses = $statuses }
        }
        Start-Sleep -Seconds 1
    }
    throw "Özet sayıları $Attempts denemede durağan bir ana denk gelmedi (faturalar sürekli değişiyor)."
}
