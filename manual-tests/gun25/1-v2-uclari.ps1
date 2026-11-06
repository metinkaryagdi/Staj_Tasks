# ERP Simulator 1-4: v2 uçları, kuruş, mükerrer, haber biçimi, v1'in kapatılması ve yeniden açılması. Simülatör hatasız (Success 100).
# Çıktı manual-tests\output\gun25\a-v2-uclari.txt.
#   .\manual-tests\gun25\1-v2-uclari.ps1
. "$PSScriptRoot\_common.ps1"
Use-Gun10Volumes 'gun25-uclar'
New-Report 'a-v2-uclari'
Write-Title 'ERP Simulator: yeni sürüm'
Start-Stack
$noFaults = @{ Simulator__Rates__Success = 100; Simulator__Rates__Busy = 0; Simulator__Rates__ServerError = 0; Simulator__Rates__SaveThenError = 0; Simulator__Rates__LateResponse = 0; Simulator__LateResponseDelaySeconds = 0 }
Restart-Simulator $noFaults
$tag = Get-Date -Format 'HHmmss'
$v2 = "V2-$tag"; $v1 = "V1-$tag"
function Body2([string]$Number, [string]$Customer = 'C-1', $Amount = 12345) { "{`"invoiceNumber`":`"$Number`",`"customerCode`":`"$Customer`",`"amountKurus`":$Amount,`"currency`":`"TRY`",`"invoiceDate`":`"2026-11-06`"}" }

Write-Line '1) Tutar kuruş olarak alınıp veriliyor'
$a = Send-Erp POST '/api/v2/invoices' (Body2 $v2)
Check ($a.Status -eq 202 -and $a.Json.amountKurus -eq 12345) "POST v2 amountKurus=12345: HTTP $($a.Status), cevapta amountKurus=$($a.Json.amountKurus)"
$g = Send-Erp GET "/api/v2/invoices/$v2"
Check ($g.Json.records[0].amountKurus -eq 12345) "GET v2: amountKurus=$($g.Json.records[0].amountKurus)"
$g1 = Send-Erp GET "/api/v1/invoices/$v2"
Check ($g1.Json.records[0].amount -eq 123.45) "Aynı kayıt GET v1: amount=$($g1.Json.records[0].amount)"
$from = [Uri]::EscapeDataString((Get-Date).ToUniversalTime().AddHours(-1).ToString('o')); $to = [Uri]::EscapeDataString((Get-Date).ToUniversalTime().AddHours(1).ToString('o'))
$l = Send-Erp GET "/api/v2/invoices?from=$from&to=$to&pageSize=500"
Check (@($l.Json.items | Where-Object { $_.invoiceNumber -eq $v2 -and $_.amountKurus -eq 12345 }).Count -eq 1) "Liste v2: amountKurus=12345"
$d = Send-Erp POST '/api/v2/invoices' (Body2 "$v2-X" 'C-1' '123.45')
Check ($d.Status -eq 400) "Ondalık tutar: HTTP $($d.Status)"
$z = Send-Erp POST '/api/v2/invoices' (Body2 "$v2-Y" 'C-1' 0)
Check ($z.Status -eq 400) "Sıfır tutar: HTTP $($z.Status)"

Write-Line ''
Write-Line '2) Aynı numara ikinci kez: yeni kayıt yok, mevcut kayıt dönüyor'
$b = Send-Erp POST '/api/v2/invoices' (Body2 $v2 'C-FARKLI' 99999)
Check ($b.Status -eq 202 -and $b.Json.erpReference -eq $a.Json.erpReference -and $b.Json.amountKurus -eq 12345 -and $b.Json.customerCode -eq 'C-1') "İçerik farklı ikinci POST: HTTP $($b.Status), aynı referans $($b.Json.erpReference), mevcut tutar $($b.Json.amountKurus)"
$count = Get-SqlScalar "SELECT count(*) FROM invoices WHERE invoice_number = '$v2'"
Check ($count -eq '1') "ERP'de kayıt sayısı: $count"

Write-Line ''
Write-Line '3) Haber biçimi faturanın alındığı sürüme göre'
$v1Body = "{`"invoiceNumber`":`"$v1`",`"customerCode`":`"C-1`",`"amount`":10.50,`"currency`":`"TRY`",`"invoiceDate`":`"2026-11-06`"}"
$c = Send-Erp POST '/api/v1/invoices' $v1Body
Check ($c.Status -eq 202) "POST v1: HTTP $($c.Status)"
$cancel = Send-Erp POST "/api/v2/invoices/$v1/cancel"
Check ($cancel.Status -eq 202) "v1 faturasının iptali v2 ile: HTTP $($cancel.Status)"
$cancel2 = Send-Erp POST "/api/v2/invoices/$v2/cancel"
Show-Rows 'Haberler:' "SELECT invoice_number, event_type, left(payload, 60) FROM webhook_deliveries WHERE invoice_number IN ('$v1','$v2') ORDER BY 1, id" -Erp
$wrongV1 = Get-SqlScalar "SELECT count(*) FROM webhook_deliveries WHERE invoice_number = '$v1' AND payload::jsonb ? 'schema'"
$wrongV2 = Get-SqlScalar "SELECT count(*) FROM webhook_deliveries WHERE invoice_number = '$v2' AND coalesce(payload::jsonb ->> 'schema', '') <> 'erp.invoice-event.v2'"
Check ($wrongV1 -eq '0') "v1 faturasının (iptali dahil) yeni biçimde haberi: $wrongV1"
Check ($wrongV2 -eq '0') "v2 faturasının eski biçimde haberi: $wrongV2"

Write-Line ''
Write-Line '4) Eski sürüm ayarla kapatılıyor'
Restart-Simulator ($noFaults + @{ Simulator__V1Enabled = 'false' })
foreach ($try in @(@('POST', '/api/v1/invoices', $v1Body), @('GET', "/api/v1/invoices/$v1", $null), @('GET', "/api/v1/invoices?from=$from&to=$to", $null), @('POST', "/api/v1/invoices/$v1/cancel", $null))) {
    $r = Send-Erp $try[0] $try[1] $try[2]
    Check ($r.Status -eq 410 -and $r.Json.title -eq 'API version closed') "$($try[0]) $($try[1] -replace '\?.*', ''): HTTP $($r.Status), $($r.Json.title)"
}
$open = Send-Erp GET "/api/v2/invoices/$v1"
Check ($open.Status -eq 200 -and $open.Json.records[0].amountKurus -eq 1050) "v2 açık, eski fatura okunuyor: HTTP $($open.Status), amountKurus=$($open.Json.records[0].amountKurus), iptal $($open.Json.cancelReference)"

Write-Line ''
Write-Line 'Ayar geri açılınca v1 çalışıyor'
Restart-Simulator ($noFaults + @{ Simulator__V1Enabled = 'true' })
$back = Send-Erp GET "/api/v1/invoices/$v1"
Check ($back.Status -eq 200) "GET v1: HTTP $($back.Status)"
Restart-Simulator
Save-Report
