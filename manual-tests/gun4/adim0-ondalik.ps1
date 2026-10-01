# Gün 4 - Adım 0 (Gün 3'ten kalan düzeltme): virgülden sonra ikiden fazla basamağı olan tutar iki uygulamada da 400.
# Sondaki sıfırlar basamak sayılmaz: 1.230 ve 1.2300, 1.23 ile aynı değerdir ve kabul edilir. ~1 dk.
#
#   A) Fatura Servisi: 1.234 -> 400 ve invoices tablosuna kayıt yok; 1.230, 1.2300, 1.23 -> 202, amount = 1.23.
#   B) ERP Simülatörü (Success %100): aynı dört tutar doğrudan gönderilir; 1.234 -> 400 ve kayıt yok, diğerleri
#      202, amount = 1.23.
#
# Önce simülatörün yeni kodla derlenmiş olması gerekir: docker compose up -d --build
# Sonunda simülatör varsayılan ayarlarına döner.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: $_ - simülatör varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Restart-Simulator } catch { }; break }

Write-Title 'Adım 0) İkiden fazla ondalıklı tutar: iki uygulamada da 400, sondaki sıfırlar kabul'

# Beklenen HTTP kodu tutara göre. JSON'a metin olarak yazılır: PowerShell sayıya çevirirse sondaki sıfırlar kaybolur.
$cases = [ordered]@{ '1.234' = 400; '1.230' = 202; '1.2300' = 202; '1.23' = 202 }
$allPassed = $true

# --- A) Fatura Servisi ---------------------------------------------------------------------------------------------
Wait-Service
Write-Step 'A) Fatura Servisi: POST /api/v1/invoices'
$created = @()
foreach ($amount in $cases.Keys) {
    $before = [int]@(Get-ServiceRows 'SELECT count(*) FROM invoices;')[0]
    $json = '{"customerCode":"C-001","amount":' + $amount + ',"currency":"TRY","invoiceDate":"2026-10-01"}'
    $r = Send-Json "$ServiceUrl/api/v1/invoices" $json
    $after = [int]@(Get-ServiceRows 'SELECT count(*) FROM invoices;')[0]
    $number = if ($r.Body -match '"invoiceNumber":"([^"]+)"') { $Matches[1] } else { '-' }
    if ($number -ne '-') { $created += $number }
    $ok = $r.Status -eq $cases[$amount] -and ($after - $before) -eq [int]($cases[$amount] -eq 202)
    if (-not $ok) { $allPassed = $false }
    Write-Host ('  amount={0,-7} -> HTTP {1} (beklenen {2}), invoices satır sayısı {3} -> {4}, fatura {5}' -f `
        $amount, $r.Status, $cases[$amount], $before, $after, $number) -ForegroundColor ($(if ($ok) { 'Gray' } else { 'Red' }))
    if ($r.Status -eq 400) { Write-Host "    400 gövdesi: $($r.Body)" -ForegroundColor DarkGray }
}

Write-DbHeader 'Fatura Servisi' 'Kabul edilen faturalar 1.23 olarak kaydedildi mi?'
$inList = ($created | ForEach-Object { "'$_'" }) -join ','
$sql = "SELECT invoice_number, amount, status FROM invoices WHERE invoice_number IN ($inList) ORDER BY invoice_number;"
Show-ServiceQuery $sql
$amounts = @(Get-ServiceRows "SELECT amount FROM invoices WHERE invoice_number IN ($inList);")
$dbOk = Write-DbVerdict '3 satır, hepsinde amount = 1.23' "$($amounts.Count) satır, amount: $($amounts -join ', ')" `
    ($amounts.Count -eq 3 -and @($amounts | Where-Object { $_ -ne '1.23' }).Count -eq 0)
if (-not $dbOk) { $allPassed = $false }

# --- B) ERP Simülatörü ---------------------------------------------------------------------------------------------
Restart-Simulator @{ Simulator__Rates__Success = 100; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0
                     Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0 }
$prefix = New-Prefix 'ONDALIK'
Write-Step 'B) ERP Simülatörü: POST /api/v1/invoices (doğrudan)'
$i = 0
foreach ($amount in $cases.Keys) {
    $i++
    $number = "$prefix$i"
    $json = '{"invoiceNumber":"' + $number + '","customerCode":"C-001","amount":' + $amount + ',"currency":"TRY","invoiceDate":"2026-10-01"}'
    $r = Send-Json "$SimulatorUrl/api/v1/invoices" $json
    $saved = [int](Get-SqlScalar "SELECT count(*) FROM invoices WHERE invoice_number = '$number';")
    $ok = $r.Status -eq $cases[$amount] -and $saved -eq [int]($cases[$amount] -eq 202)
    if (-not $ok) { $allPassed = $false }
    Write-Host ('  {0} amount={1,-7} -> HTTP {2} (beklenen {3}), simülatörde kayıt {4}' -f `
        $number, $amount, $r.Status, $cases[$amount], $saved) -ForegroundColor ($(if ($ok) { 'Gray' } else { 'Red' }))
    if ($r.Status -eq 400) { Write-Host "    400 gövdesi: $($r.Body)" -ForegroundColor DarkGray }
}

Write-DbHeader 'ERP Simülatörü' "$prefix* faturaları: 1.234 kaydedilmedi, diğerleri 1.23 olarak kaydedildi mi?"
Show-ErpQuery "SELECT invoice_number, amount, behavior FROM invoices WHERE invoice_number LIKE '$prefix%' ORDER BY invoice_number;"
$erpAmounts = @(Get-ErpRows "SELECT invoice_number || '=' || amount FROM invoices WHERE invoice_number LIKE '$prefix%' ORDER BY invoice_number;")
$expected = @("${prefix}2=1.23", "${prefix}3=1.23", "${prefix}4=1.23")
$erpOk = Write-DbVerdict "${prefix}1 yok; 2, 3, 4 amount = 1.23" ($erpAmounts -join ', ') `
    (($erpAmounts -join ',') -eq ($expected -join ','))
if (-not $erpOk) { $allPassed = $false }

Restart-Simulator
Write-Result $allPassed '1.234 iki uygulamada da 400 ve kaydedilmiyor; 1.230, 1.2300, 1.23 kabul ediliyor, 1.23 olarak kaydediliyor'
