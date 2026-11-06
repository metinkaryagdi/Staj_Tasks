# Gün 25 script'lerinin ortak yardımcıları. Gün 24'ün _common.ps1'ini yükler. Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun24\_common.ps1"

$OutputDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'output\gun25'
New-Item -ItemType Directory -Force $OutputDir | Out-Null

$SimulatorUrl = 'http://127.0.0.1:5080'
$SimulatorEnvKeys = @($SimulatorEnvKeys) + 'Simulator__V1Enabled'

# Simülatöre doğrudan istek; hata kodunda da cevabı döner.
function Send-Erp([string]$Method, [string]$Path, $Json = $null) {
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), "$SimulatorUrl$Path")
    if ($null -ne $Json) { $request.Content = [Net.Http.StringContent]::new($Json, [Text.Encoding]::UTF8, 'application/json') }
    $response = $script:ApiHttp.SendAsync($request).GetAwaiter().GetResult()
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $parsed = $null
    try { if ($body -and $body.TrimStart().StartsWith('{')) { $parsed = $body | ConvertFrom-Json } } catch { }
    [pscustomobject]@{ Status = [int]$response.StatusCode; Body = $body; Json = $parsed }
}

# Dokümandaki gibi, operatör token'ıyla yüzdeyi değiştirir.
function Set-V2Percent([int]$Percent) {
    $r = Send-Api PUT '/api/v1/erp-version' (Get-UserToken 'operator') "{`"v2Percent`":$Percent}"
    if ($r.Status -ne 200) { throw "Yüzde değiştirilemedi: HTTP $($r.Status) $($r.Body)" }
}
