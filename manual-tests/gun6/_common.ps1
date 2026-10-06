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
