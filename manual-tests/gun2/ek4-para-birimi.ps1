# Gün 2 - Ek test 4 (QA bulgusu 4'ün düzeltmesi): para birimi tam olarak 3 büyük harf olmalı ("currency: 3 harf").
# Düzeltmeden önce "TRY\n" (sonunda satır sonu, 4 karakter) kabul ediliyordu: .NET'te regex'teki $ sondaki satır
# sonunun önüne de uyuyor. Cevapta "TRY\n", veritabanında (char(3) sütunu kestiği için) "TRY" görünüyordu.
#
# Her değer POST edilir. Geçersizler 400 almalı; tabloya satır eklenmemeli, fatura numarası harcanmamalı,
# simülatöre istek gitmemeli. Geçerli olan (TRY) 201 almalı ve cevaptaki para birimi veritabanındakiyle aynı olmalı.
. "$PSScriptRoot\_common.ps1"

Write-Title 'Ek 4) Para birimi tam olarak 3 büyük harf: "TRY\n" gibi değerler reddediliyor'
Wait-Service

$tag = 'EK4-' + (Get-Date -Format 'HHmmss')
$cases = @(
    @{ Show = '"TRY\n"';   Value = "TRY`n";   Valid = $false }
    @{ Show = '"TRY\r\n"'; Value = "TRY`r`n"; Valid = $false }
    @{ Show = '" TRY"';    Value = ' TRY';    Valid = $false }
    @{ Show = '"TRY "';    Value = 'TRY ';    Valid = $false }
    @{ Show = '"try"';     Value = 'try';     Valid = $false }
    @{ Show = '"TRYY"';    Value = 'TRYY';    Valid = $false }
    @{ Show = '"TRY"';     Value = 'TRY';     Valid = $true }
)

function Get-State {
    $row = @(Get-ServiceRows "SELECT count(*), (SELECT last_value FROM invoice_number_seq) FROM invoices;")[0] -split '\|'
    $erpPosts = @(Get-SimulatorLog | Where-Object { $_ -match 'ERP request #\d+ ' -and $_ -match 'behavior=' }).Count
    [pscustomobject]@{ Rows = [int]$row[0]; Sequence = [long]$row[1]; ErpPosts = $erpPosts }
}

$allPassed = $true
$created = @()
$rejected = 0
foreach ($case in $cases) {
    Write-Step "currency = $($case.Show)"
    $json = @{ customerCode = $tag; amount = 10.00; currency = $case.Value; invoiceDate = '2026-09-30' } | ConvertTo-Json -Compress
    Write-Host "  Gövde: $json"
    $before = Get-State
    $content = New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')
    $response = $script:Http.PostAsync("$ServiceUrl/api/v1/invoices", $content).GetAwaiter().GetResult()
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $after = Get-State
    $code = [int]$response.StatusCode
    Write-Host "  HTTP $code  $body"
    Write-Host ("  Tablo: {0} -> {1} satır, sequence: {2} -> {3}, simülatöre giden POST: {4} -> {5}" -f `
        $before.Rows, $after.Rows, $before.Sequence, $after.Sequence, $before.ErpPosts, $after.ErpPosts)

    if ($case.Valid) {
        $invoice = $body | ConvertFrom-Json
        $created += $invoice.invoiceNumber
        $dbCurrency = @(Get-ServiceRows "SELECT currency FROM invoices WHERE invoice_number = '$($invoice.invoiceNumber)';")[0]
        $ok = $code -eq 201 -and $after.Rows -eq $before.Rows + 1 -and $invoice.currency -ceq 'TRY' -and $dbCurrency -ceq 'TRY'
        Write-DbVerdict '201; 1 satır eklendi; cevaptaki ve veritabanındaki para birimi aynı: TRY' `
            "$code; $($after.Rows - $before.Rows) satır; cevapta '$($invoice.currency)', veritabanında '$dbCurrency'" $ok | Out-Null
    }
    else {
        if ($code -eq 400) { $rejected++ }
        $ok = $code -eq 400 -and $body -match 'Currency' -and $after.Rows -eq $before.Rows -and
            $after.Sequence -eq $before.Sequence -and $after.ErpPosts -eq $before.ErpPosts
        Write-DbVerdict '400 (Currency); satır eklenmedi, numara harcanmadı, simülatöre gitmedi' `
            "$code; $($after.Rows - $before.Rows) satır, sequence +$($after.Sequence - $before.Sequence), simülatöre +$($after.ErpPosts - $before.ErpPosts)" $ok | Out-Null
    }
    $allPassed = $allPassed -and $ok
}

Write-DbHeader 'Ek 4: bu testte oluşan faturalar' "Müşteri kodu: $tag"
Show-ServiceQuery ("SELECT invoice_number, customer_code, currency, length(currency) AS uzunluk, " +
    "encode(convert_to(currency, 'UTF8'), 'hex') AS hex, status FROM invoices WHERE customer_code = '$tag' ORDER BY 1;")
Show-ErpQuery "SELECT invoice_number, currency, erp_reference, behavior FROM invoices WHERE customer_code = '$tag' ORDER BY id;"
$serviceRows = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE customer_code = '$tag';")[0]
Write-Host ''
$dbOk = Write-DbVerdict "serviste bu müşteri koduyla yalnızca geçerli değerin (TRY) faturası: 1 satır" "$serviceRows satır" ($serviceRows -eq 1)

Write-Result ($allPassed -and $dbOk) ("$($cases.Count - 1) geçersiz değerden $rejected tanesi 400 ile reddedildi; " +
    "TRY ile oluşan: $($created -join ', '); veritabanı kontrolü: $(if ($dbOk) { 'geçti' } else { 'KALDI' })")
