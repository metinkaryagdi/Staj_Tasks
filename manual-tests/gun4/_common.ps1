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
