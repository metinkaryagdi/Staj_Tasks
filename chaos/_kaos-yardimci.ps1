# Kaos otomasyonunun yardımcıları: docker compose, iki veritabanı, token, Fatura Servisi'ne istek, simülatörün ayarı ve
# arızaların başlatılıp bitirilmesi. kaos.ps1 yükler; doğrudan çalıştırılmaz.
# Windows PowerShell 5.1'de 'Stop', docker'ın stderr'e yazdığı her satırı (ilerleme satırları dahil) hataya çevirir; hatalar
# aşağıda açıkça ele alınır.
$ErrorActionPreference = 'Continue'
$RepoRoot = Split-Path $PSScriptRoot -Parent
$ServiceUrl = 'http://127.0.0.1:5090'
$SimulatorUrl = 'http://127.0.0.1:5080'
$KeycloakUrl = 'http://localhost:8080'
$Bash = 'C:\Program Files\Git\bin\bash.exe'

# Simülatörün arızalarda değiştirilen ayarları; arıza bitince hepsi kaldırılır, simülatör appsettings.json'a döner.
$SimulatorKeys = @(
    'Simulator__Rates__Success', 'Simulator__Rates__Busy', 'Simulator__Rates__ServerError', 'Simulator__Rates__SaveThenError',
    'Simulator__Rates__LateResponse', 'Simulator__V1Enabled', 'Webhooks__Problems__LostDecisionRate', 'Webhooks__Problems__DuplicateRate')

function Get-DotEnvValue([string]$Name) {
    $line = Get-Content (Join-Path $RepoRoot '.env') -Encoding UTF8 | Where-Object { $_ -cmatch "^$Name=" } | Select-Object -First 1
    if (-not $line) { throw "$Name .env dosyasında yok." }
    $line.Substring($Name.Length + 1).Trim()
}

# docker compose, repo kökünde ve koşunun volume'leriyle (COMPOSE_FILE, KAOS_VOL kaos.ps1'de verilir). Çıktı satır satır döner.
function Invoke-Compose([string[]]$Arguments) {
    Push-Location $RepoRoot
    try { & docker compose @Arguments 2>&1 | ForEach-Object { "$_" } }
    finally { Pop-Location }
}

# psql, veritabanının sahibiyle. SQL'de çift tırnak kullanılmaz: Windows PowerShell 5.1 onu docker'a geçirirken düşürür.
# Sorgu çalışmazsa (örn. veritabanı kaybı sırasında) -Strict hata fırlatır, değilse boş döner.
function Invoke-Psql([string]$Service, [string]$User, [string]$Database, [string]$Sql, [switch]$Strict) {
    Push-Location $RepoRoot
    try { $text = ((& docker compose exec -T $Service psql -U $User -d $Database -v ON_ERROR_STOP=1 -tAc $Sql 2>&1) | Out-String).Trim() }
    finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) {
        if ($Strict) { throw "Sorgu çalışmadı ($Service): $text" }
        return ''
    }
    $text
}
function Invoke-InvoiceSql([string]$Sql, [switch]$Strict) { Invoke-Psql invoice-db invoice invoice_service $Sql -Strict:$Strict }
function Invoke-ErpSql([string]$Sql, [switch]$Strict) { Invoke-Psql erp-db erp erp_simulator $Sql -Strict:$Strict }

# Sorgunun satırları, her biri '|' ile ayrılmış sütunlar. Liste tek nesne olarak döner: tek satırlık sonuç da satır listesidir.
function Get-Rows([string]$Text) {
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($line in ($Text -split "`r?`n")) { if ($line.Trim()) { $rows.Add([string[]]($line -split '\|')) } }
    , $rows
}

# Bir zaman sütununun UTC ISO metni (sonu Z), PowerShell'de [DateTimeOffset]::Parse ile okunur.
function Iso([string]$Column) { "to_char($Column AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.MS') || 'Z'" }

Add-Type -AssemblyName System.Net.Http
$script:Http = New-Object System.Net.Http.HttpClient
$script:Http.Timeout = [TimeSpan]::FromSeconds(15)

# Fatura Servisi'ne istek: önce kopya 1, cevap gelmezse kopya 2 (arızalardan biri kopyayı kapatmış olabilir; ikisi aynı
# veritabanını kullanır). İkisi de kapalıysa Status 0 döner.
$ServiceUrls = @($ServiceUrl, 'http://127.0.0.1:5091')
function Send-Api([string]$Method, [string]$Path, $Token = $null, $Json = $null) {
    $result = $null
    foreach ($base in $ServiceUrls) {
        try {
            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), "$base$Path")
            if ($Token) { $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token) }
            if ($null -ne $Json) { $request.Content = [Net.Http.StringContent]::new($Json, [Text.Encoding]::UTF8, 'application/json') }
            $response = $script:Http.SendAsync($request).GetAwaiter().GetResult()
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $parsed = $null
            try { if ($body -and $body.TrimStart().StartsWith('{')) { $parsed = $body | ConvertFrom-Json } } catch { }
            return [pscustomobject]@{ Status = [int]$response.StatusCode; Body = $body; Json = $parsed }
        }
        catch { $result = [pscustomobject]@{ Status = 0; Body = "$_"; Json = $null } }
    }
    $result
}

# Operatörün token'ı (iptal, sürüm yüzdesi, mutabakat): yerel test client'ı fatura-test ile, kullanıcı operator. Client
# varsayılan kurulumda yok; ilk token'dan önce manual-tests\keycloak\test-client-ekle.ps1 ekler. 4 dakikada bir yenilenir.
$script:TokenAt = [datetime]::MinValue
function Get-OperatorToken {
    if (((Get-Date) - $script:TokenAt).TotalMinutes -lt 4) { return $script:Token }
    if ($script:TokenAt -eq [datetime]::MinValue) { & (Join-Path $RepoRoot 'manual-tests\keycloak\test-client-ekle.ps1') -KeycloakUrl $KeycloakUrl }
    try {
        $fields = [Collections.Generic.Dictionary[string, string]]::new()
        $fields.Add('grant_type', 'password'); $fields.Add('client_id', 'fatura-test'); $fields.Add('username', 'operator')
        $fields.Add('password', (Get-DotEnvValue 'TEST_OPERATOR_PASSWORD'))
        $form = [Net.Http.FormUrlEncodedContent]::new($fields)
        $response = $script:Http.PostAsync("$KeycloakUrl/realms/fatura/protocol/openid-connect/token", $form).GetAwaiter().GetResult()
        $token = ($response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json).access_token
        if ($token) { $script:Token = $token; $script:TokenAt = Get-Date }
    }
    catch { Write-Host "  Operatör token'ı alınamadı: $_" }
    $script:Token
}

# Bir adres 200 dönüyor mu; HttpClient'ın süre sınırı isteğin tamamını kapsar.
$script:Probe = New-Object System.Net.Http.HttpClient
$script:Probe.Timeout = [TimeSpan]::FromSeconds(3)
function Test-Up([string]$Url) {
    try {
        $response = $script:Probe.GetAsync($Url).GetAwaiter().GetResult()
        $ok = [int]$response.StatusCode -eq 200
        $response.Dispose()
        $ok
    }
    catch { $false }
}
function Wait-For([scriptblock]$Condition, [int]$TimeoutSeconds, [string]$What) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not (& $Condition)) {
        if ((Get-Date) -gt $deadline) { throw "$What $TimeoutSeconds sn içinde olmadı." }
        Start-Sleep -Seconds 2
    }
}

# İki kopya da kapalıysa (örn. veritabanı kaybının geri dönüşü sürerken) biri açılana kadar, en çok 3 dakika denenir.
function Set-V2Percent([int]$Percent) {
    $deadline = (Get-Date).AddMinutes(3)
    do {
        $r = Send-Api PUT '/api/v1/erp-version' (Get-OperatorToken) "{`"v2Percent`":$Percent}"
        if ($r.Status -eq 200) { return }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw "Sürüm yüzdesi $Percent yapılamadı: HTTP $($r.Status) $($r.Body)"
}

# Simülatörün o ana kadarki logu dosyaya eklenir: container yeniden yaratılınca eski logu gider, iptal sırası kontrolü bu
# dosyadan okur.
function Save-SimulatorLog {
    Invoke-Compose @('logs', '--no-color', '--no-log-prefix', '--timestamps', 'erp-simulator') |
        Add-Content -Path $script:SimulatorLogFile -Encoding UTF8
}

# Simülatörü verilen ayarlarla (boşsa appsettings.json'la) yeniden yaratır ve hazır olmasını bekler.
function Reset-Simulator([hashtable]$Settings = @{}) {
    Save-SimulatorLog
    foreach ($key in $SimulatorKeys) { Remove-Item "Env:$key" -ErrorAction SilentlyContinue }
    foreach ($key in $Settings.Keys) { Set-Item "Env:$key" ([string]$Settings[$key]) }
    try { [void](Invoke-Compose @('up', '-d', '--no-deps', '--force-recreate', 'erp-simulator')) }
    finally { foreach ($key in $SimulatorKeys) { Remove-Item "Env:$key" -ErrorAction SilentlyContinue } }
    Wait-For { Test-Up "$SimulatorUrl/health" } 90 'Simülatörün açılması'
}

function Get-ContainerId([string]$Service) { (Invoke-Compose @('ps', '-q', $Service) | Select-Object -First 1).Trim() }

# Arızanın başlangıcı. Veritabanı kaybı burada değil, kaos.ps1'de arka plan işi olarak çalışır (uzun sürer).
function Start-Fault($Fault) {
    switch ($Fault.Key) {
        'erp-cokmesi' { [void](Invoke-Compose @('kill', 'erp-simulator')) }
        'erp-yavaslamasi' {
            # Gönderimlerin çoğu 30 sn sonra cevap alır (servis 10 sn'de vazgeçer); oranların toplamı 100.
            Reset-Simulator @{ Simulator__Rates__Success = 25; Simulator__Rates__Busy = 5; Simulator__Rates__ServerError = 5
                Simulator__Rates__SaveThenError = 5; Simulator__Rates__LateResponse = 60 }
        }
        'ag-kopmasi' {
            $script:ErpContainer = Get-ContainerId 'erp-simulator'
            $out = docker network disconnect staj-tasks_apps $script:ErpContainer 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Simülatör ağdan çıkarılamadı: $out" }
        }
        'worker-olmesi' { [void](Invoke-Compose @('kill', 'invoice-service')) }
        'kopya-olmesi' { [void](Invoke-Compose @('kill', 'invoice-service-2')) }
        'haber-kaybi' { Reset-Simulator @{ Webhooks__Problems__LostDecisionRate = 50; Webhooks__Problems__DuplicateRate = 30 } }
        'surum-gecisi' {
            if ($Fault.V1Closed) { Reset-Simulator @{ Simulator__V1Enabled = 'false' } }
            Set-V2Percent $Fault.Percent
            $script:V2Percent = $Fault.Percent
        }
    }
}

# Arızanın bitişi: her şey kurulumdaki haline döner.
function Stop-Fault($Fault) {
    switch ($Fault.Key) {
        'erp-cokmesi' { [void](Invoke-Compose @('start', 'erp-simulator')); Wait-For { Test-Up "$SimulatorUrl/health" } 90 'Simülatörün açılması' }
        'erp-yavaslamasi' { Reset-Simulator }
        'ag-kopmasi' {
            # Servisler simülatöre bu adla ulaşır; yeniden bağlanırken ad verilmezse çözülmez.
            $out = docker network connect --alias erp-simulator staj-tasks_apps $script:ErpContainer 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Simülatör ağa geri bağlanamadı: $out" }
        }
        'worker-olmesi' { [void](Invoke-Compose @('start', 'invoice-service')) }
        'kopya-olmesi' { [void](Invoke-Compose @('start', 'invoice-service-2')) }
        'haber-kaybi' { Reset-Simulator }
        'surum-gecisi' {
            Set-V2Percent 0
            $script:V2Percent = 0
            if ($Fault.V1Closed) { Reset-Simulator }
        }
    }
}

# Veritabanı kaybı, arka plan işinde: FELAKET-KITAPCIGI.md'deki gibi ikinci kopya durdurulur, veritabanı container'ı ve volume'ü
# silinir, scripts/restore-invoice-db.sh son yedekten döner, ikinci kopya açılır. Çıktıda "SILINDI <zaman>" ve betiğin satırları.
$DatabaseLossJob = {
    param($root, $composeFile, $vol, $backupDir, $bash)
    Set-Location $root
    $env:COMPOSE_FILE = $composeFile; $env:KAOS_VOL = $vol; $env:INVOICE_BACKUP_DIR = $backupDir; $env:COMPOSE_PROFILES = 'iki-kopya'
    docker compose stop invoice-service-2 2>&1 | Out-Null
    docker compose rm -sf invoice-db 2>&1 | Out-Null
    docker volume rm "staj-tasks_invoice-db-data-kaos-$vol" 2>&1 | Out-Null
    "SILINDI $([DateTimeOffset]::UtcNow.ToString('o'))"
    & $bash scripts/restore-invoice-db.sh 2>&1 | ForEach-Object { "$_" }
    docker compose up -d --no-deps invoice-service-2 2>&1 | Out-Null
    "BITTI $([DateTimeOffset]::UtcNow.ToString('o'))"
}
