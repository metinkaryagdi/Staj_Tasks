# Gün 20 (güvenlik gözden geçirmesi) script'lerinin ortak yardımcıları. Gün 18'in _common.ps1'ini yükler (token alma, API
# isteği, rapor dosyası, Keycloak yönetim API'si, Gün 1-17 yardımcıları dahil). Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun18\_common.ps1"

# Bu güne özel volume'ler (staj-tasks_*-db-data-gun20); eski volume'lere dokunulmaz.
Use-Gun10Volumes 'gun20'

# Çıktılar günün klasörüne yazılır.
$OutputDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'output\gun20'
New-Item -ItemType Directory -Force $OutputDir | Out-Null

# Bilgisayarın yerel ağdaki adresi: bir porta bu adresten ulaşılabiliyorsa aynı ağdaki başka bir makine de ulaşabilir
# (yalnız 127.0.0.1'e bağlı bir port bu adresten açılmaz).
function Get-LanAddress {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1
    (Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 | Select-Object -First 1).IPAddress
}

# Port bu adreste bağlantı kabul ediyor mu (1 sn içinde).
function Test-Port([string]$Address, [int]$Port) {
    $client = [Net.Sockets.TcpClient]::new()
    try { $client.ConnectAsync($Address, $Port).Wait(1000) -and $client.Connected } catch { $false } finally { $client.Dispose() }
}

# Basit bir HTTP isteği: durum kodu, başlıklar ve gövde. Hata kodları da exception'sız döner.
$script:PlainHttp = [Net.Http.HttpClient]::new([Net.Http.HttpClientHandler]@{ AllowAutoRedirect = $false })
$script:PlainHttp.Timeout = [TimeSpan]::FromSeconds(15)
function Send-Http([string]$Method, [string]$Url, [hashtable]$Headers = @{}, $Body = $null, [string]$ContentType = 'application/json') {
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $Url)
    foreach ($key in $Headers.Keys) { [void]$request.Headers.TryAddWithoutValidation($key, $Headers[$key]) }
    if ($null -ne $Body) { $request.Content = [Net.Http.StringContent]::new($Body, [Text.Encoding]::UTF8, $ContentType) }
    try {
        $response = $script:PlainHttp.SendAsync($request).GetAwaiter().GetResult()
        $headerMap = @{}
        foreach ($h in @($response.Headers) + @($response.Content.Headers)) { $headerMap[$h.Key.ToLowerInvariant()] = ($h.Value -join ', ') }
        [pscustomobject]@{ Status = [int]$response.StatusCode; Headers = $headerMap
            Body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
    }
    catch { [pscustomobject]@{ Status = 0; Headers = @{}; Body = $_.Exception.GetBaseException().Message } }
}

function Get-BasicAuth([string]$User, [string]$Password) {
    'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${User}:$Password"))
}
