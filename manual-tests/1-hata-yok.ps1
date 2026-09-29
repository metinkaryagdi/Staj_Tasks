# Test 1: Hata oranları 0 iken 100 fatura gönder.
# Beklenen: 100 başarılı cevap (202), veritabanında 100 kayıt.
param([int]$Count = 100)
. "$PSScriptRoot\_common.ps1"

Write-Title "1) Hata oranları 0 -> $Count fatura: hepsi 202, veritabanında $Count kayıt"

Restart-Simulator @{
    Simulator__Rates__Busy          = 0
    Simulator__Rates__ServerError   = 0
    Simulator__Rates__SaveThenError = 0
    Simulator__Rates__LateResponse  = 0
}

$prefix = New-Prefix 'T1'
Write-Step "$Count fatura gönderiliyor (fatura no: $prefix<1..$Count>)"
$results = foreach ($i in 1..$Count) {
    $r = Send-Invoice "$prefix$i"
    Write-Response $r
    $r
}

$accepted = @($results | Where-Object Status -eq 202).Count
$dbOk = Test-DbAllSaved -Title "Test 1: $Count kayıt, hepsi Success" -Prefix $prefix -Count $Count -Behavior 'Success'

Write-Result ($accepted -eq $Count -and $dbOk) "202 cevap: $accepted/$Count, veritabanı kontrolü: $(if ($dbOk) { 'geçti' } else { 'kaldı' })"

Restart-Simulator
