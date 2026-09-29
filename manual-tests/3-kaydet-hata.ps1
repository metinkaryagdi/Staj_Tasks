# Test 3: Kaydedip hata dönme oranı %100 iken.
# Beklenen: her istek 500 döner ama her fatura veritabanında var.
param([int]$Count = 20)
. "$PSScriptRoot\_common.ps1"

Write-Title "3) Kaydedip hata %100 -> $Count istek: hepsi 500, veritabanında $Count kayıt"

Restart-Simulator @{
    Simulator__Rates__Success       = 0
    Simulator__Rates__Busy          = 0
    Simulator__Rates__ServerError   = 0
    Simulator__Rates__SaveThenError = 100
    Simulator__Rates__LateResponse  = 0
}

$prefix = New-Prefix 'T3'
Write-Step "$Count fatura gönderiliyor (fatura no: $prefix<1..$Count>)"
$results = foreach ($i in 1..$Count) {
    $r = Send-Invoice "$prefix$i"
    Write-Response $r
    $r
}

$errors = @($results | Where-Object Status -eq 500).Count
$dbOk = Test-DbAllSaved -Title "Test 3: 500 dönen $Count faturanın hepsi kayıtlı" -Prefix $prefix -Count $Count -Behavior 'SaveThenError'

Write-Result ($errors -eq $Count -and $dbOk) "500 cevap: $errors/$Count, veritabanı kontrolü: $(if ($dbOk) { 'geçti' } else { 'kaldı' })"

Restart-Simulator
