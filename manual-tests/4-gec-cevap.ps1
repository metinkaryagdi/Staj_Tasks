# Test 4: Geç cevap oranı %100 iken.
# Beklenen: cevap 30 saniye sonra gelir (202) ve fatura veritabanında var.
# Her istek ~30 sn sürer; varsayılan 2 istek yaklaşık 1 dakika.
param([int]$Count = 2)
. "$PSScriptRoot\_common.ps1"

Write-Title "4) Geç cevap %100 -> $Count istek: her biri ~30 sn sonra 202, veritabanında $Count kayıt"

Restart-Simulator @{
    Simulator__Rates__Success       = 0
    Simulator__Rates__Busy          = 0
    Simulator__Rates__ServerError   = 0
    Simulator__Rates__SaveThenError = 0
    Simulator__Rates__LateResponse  = 100
}

$prefix = New-Prefix 'T4'
Write-Step "$Count fatura gönderiliyor, her biri ~30 sn bekleyecek (fatura no: $prefix<1..$Count>)"
$results = foreach ($i in 1..$Count) {
    Write-Host "  $(Get-Date -Format 'HH:mm:ss') gönderildi: $prefix$i ..." -ForegroundColor DarkGray
    $r = Send-Invoice "$prefix$i"
    Write-Host "  $(Get-Date -Format 'HH:mm:ss') cevap geldi" -ForegroundColor DarkGray
    Write-Response $r
    $r
}

$late = @($results | Where-Object { $_.Status -eq 202 -and $_.Seconds -ge 30 -and $_.Seconds -lt 35 }).Count
$dbOk = Test-DbAllSaved -Title "Test 4: geç cevap verilen $Count faturanın hepsi kayıtlı" -Prefix $prefix -Count $Count -Behavior 'LateResponse' -ShowRows

Write-Result ($late -eq $Count -and $dbOk) `
    "30-35 sn içinde 202: $late/$Count (süreler: $(($results | ForEach-Object { "$($_.Seconds)s" }) -join ', ')), veritabanı kontrolü: $(if ($dbOk) { 'geçti' } else { 'kaldı' })"

Restart-Simulator
