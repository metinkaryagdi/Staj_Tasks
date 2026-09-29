# Test 2: Meşgul oranı %100 iken.
# Beklenen: her istek 429 ve Retry-After başlığı (5-30 sn) döner, veritabanında hiç kayıt yok.
# -HttpDate verilirse Retry-After saniye yerine tarih biçiminde gönderilir (RFC 9110'daki ikinci biçim).
param([int]$Count = 20, [switch]$HttpDate)
. "$PSScriptRoot\_common.ps1"

Write-Title "2) Meşgul %100 -> $Count istek: hepsi 429 + Retry-After, veritabanında 0 kayıt"

$settings = @{
    Simulator__Rates__Success       = 0
    Simulator__Rates__Busy          = 100
    Simulator__Rates__ServerError   = 0
    Simulator__Rates__SaveThenError = 0
    Simulator__Rates__LateResponse  = 0
}
if ($HttpDate) { $settings['Simulator__RetryAfterFormat'] = 'HttpDate' }
Restart-Simulator $settings

$prefix = New-Prefix 'T2'
Write-Step "$Count fatura gönderiliyor (fatura no: $prefix<1..$Count>)"
$results = foreach ($i in 1..$Count) {
    # HTTP-date saniyenin altını taşımaz; karşılaştırma da tam saniye üzerinden yapılır.
    $now = [DateTimeOffset]::UtcNow
    $sentAt = $now.AddTicks(-($now.Ticks % [TimeSpan]::TicksPerSecond))
    $r = Send-Invoice "$prefix$i"
    Write-Response $r

    # Saniye biçimi doğrudan sayıdır; tarih biçimi ise istek anına göre kaç saniye sonrası olduğuna çevrilir.
    $seconds = $null
    if ($r.RetryAfter -match '^\d+$') { $seconds = [int]$r.RetryAfter }
    elseif ($r.RetryAfter) {
        $seconds = [math]::Round(([DateTimeOffset]::Parse($r.RetryAfter, [Globalization.CultureInfo]::InvariantCulture) - $sentAt).TotalSeconds)
    }
    $r | Add-Member -NotePropertyName RetrySeconds -NotePropertyValue $seconds -PassThru
}

$busy = @($results | Where-Object Status -eq 429).Count
$validHeader = @($results | Where-Object { $_.RetrySeconds -ne $null -and $_.RetrySeconds -ge 5 -and $_.RetrySeconds -le 30 }).Count
$rows = Get-DbCount $prefix
Show-DbRows $prefix

Write-Host ''
Write-Host "  Retry-After değerleri (sn): $(($results | ForEach-Object RetrySeconds) -join ' ')"
Write-Result ($busy -eq $Count -and $validHeader -eq $Count -and $rows -eq 0) `
    "429 cevap: $busy/$Count, 5-30 sn arası Retry-After: $validHeader/$Count, veritabanı: $rows kayıt"

Restart-Simulator
