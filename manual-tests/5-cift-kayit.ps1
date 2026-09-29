# Test 5: Aynı fatura numarasıyla iki istek.
# Beklenen: veritabanında farklı ERP referans numaralı iki kayıt.
. "$PSScriptRoot\_common.ps1"

Write-Title '5) Aynı fatura numarasıyla 2 istek: farklı ERP referanslı 2 kayıt'

# Hata oranları 0: iki isteğin de başarıyla kaydedildiğinden emin olmak için.
Restart-Simulator @{
    Simulator__Rates__Busy          = 0
    Simulator__Rates__ServerError   = 0
    Simulator__Rates__SaveThenError = 0
    Simulator__Rates__LateResponse  = 0
}

$number = (New-Prefix 'T5') + 'DUP'
Write-Step "Aynı fatura numarası iki kez gönderiliyor: $number"
$first = Send-Invoice $number
Write-Response $first
$second = Send-Invoice $number
Write-Response $second

$dbOk = Test-DbDuplicate -Title 'Test 5: aynı numarayla 2 kayıt, 2 farklı referans' -InvoiceNumber $number

Write-Result ($first.Status -eq 202 -and $second.Status -eq 202 -and $dbOk) `
    "cevaplar: $($first.Status), $($second.Status); referanslar: $($first.ErpReference), $($second.ErpReference); veritabanı kontrolü: $(if ($dbOk) { 'geçti' } else { 'kaldı' })"

Restart-Simulator
