# Gün 5 - Adım 2: ERP Simülatörü GET /api/v1/invoices?from=...&to=... aralıktaki kayıtları sayfalı listeler. ~1 dk.
#
#   25 fatura simülatöre doğrudan gönderilir, biri ikinci kez (aynı numara, IdempotentInvoices kapalı: iki kayıt).
#   Liste 10'arlık sayfalarla okunur ve veritabanındaki sıralı kayıtlarla karşılaştırılır:
#   aynı sayı, aynı sıra (received_at, id), çift kayıt iki satır, from dahil / to hariç, sayfa boyutu 500'ü aşamaz.
#
# Önce simülatörün yeni kodla derlenmiş olması gerekir: docker compose up -d --build
# Simülatörü yeniden başlatır; sonunda varsayılan ayarlarına döner.
. "$PSScriptRoot\_common.ps1"

trap { Write-Host "Hata: $_ - simülatör varsayılan ayarlarına döndürülüyor." -ForegroundColor Red
       try { Restart-Simulator } catch { }; break }

Write-Title 'Adım 2) GET /api/v1/invoices?from&to: aralıktaki kayıtlar, sayfalı'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

# Liste isteği: zamanlar ISO 8601; "+" gibi karakterler URL'de kaçırılır.
function Get-List([string]$From, [string]$To, $Page = 1, $PageSize = 10) {
    $query = 'from={0}&to={1}&page={2}&pageSize={3}' -f [Uri]::EscapeDataString($From), [Uri]::EscapeDataString($To), $Page, $PageSize
    $response = $script:Http.GetAsync("$BaseUrl/api/v1/invoices?$query").GetAwaiter().GetResult()
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $json = if ($response.IsSuccessStatusCode) { $body | ConvertFrom-Json } else { $null }
    [pscustomobject]@{
        Status = [int]$response.StatusCode; Body = $body; Json = $json
        ReceivedAt = @([regex]::Matches($body, '"receivedAt":"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    }
}

# Veritabanındaki zaman (UTC) -> ISO 8601 metni (mikrosaniye korunur).
function ConvertTo-Iso([string]$DbTime) { $DbTime.Replace(' ', 'T') + 'Z' }

Wait-Service
Restart-Simulator (Get-SimSettings -NoEvents)
$prefix = New-Prefix 'LISTE'
Write-Step '25 fatura simülatöre gönderiliyor, biri ikinci kez'
$numbers = 1..25 | ForEach-Object { "$prefix$_" }
foreach ($n in $numbers) { Send-Invoice $n | Out-Null }
Send-Invoice $numbers[0] | Out-Null
Write-Host "  26 kayıt: $($numbers[0]) .. $($numbers[-1]); $($numbers[0]) iki kez"

# Aralık veritabanının kendi saatinden alınır: ilk kayıt (dahil) ile son kaydın 1 sn sonrası (hariç).
$bounds = @(Get-ErpRows "SELECT to_char(min(received_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US'), to_char((max(received_at) + interval '1 second') AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') FROM invoices WHERE invoice_number LIKE '$prefix%';")[0] -split '\|'
$from = ConvertTo-Iso $bounds[0]
$to = ConvertTo-Iso $bounds[1]
Write-Host "  aralık: from=$from  to=$to"

# --- Sayfalar -----------------------------------------------------------------------------------------------------------
Write-Step 'Sayfa sayfa okuma (pageSize=10)'
$expected = @(Get-ErpRows "SELECT invoice_number FROM invoices WHERE received_at >= '$($bounds[0])+00' AND received_at < '$($bounds[1])+00' ORDER BY received_at, id;")
$got = @(); $sizes = @(); $total = $null; $page = 1; $first = $null
do {
    $r = Get-List $from $to $page 10
    if ($r.Status -ne 200) { throw "Liste $($r.Status) döndü: $($r.Body)" }
    if ($page -eq 1) { $first = $r }
    $total = $r.Json.totalCount
    $items = @($r.Json.items)
    $sizes += $items.Count
    $got += @($items | ForEach-Object { $_.invoiceNumber })
    Write-Host ('  sayfa {0}: {1} kayıt (toplam {2})' -f $page, $items.Count, $total)
    $page++
} while ($items.Count -gt 0 -and $got.Count -lt $total)

Write-DbHeader 'ERP Simülatörü' 'Aralıktaki kayıtlar, listenin sırasıyla'
Show-ErpQuery "SELECT invoice_number, erp_reference, to_char(received_at AT TIME ZONE 'UTC', 'HH24:MI:SS.US') AS alındı FROM invoices WHERE received_at >= '$($bounds[0])+00' AND received_at < '$($bounds[1])+00' ORDER BY received_at, id;"
Check (Write-DbVerdict 'toplam = veritabanındaki kayıt sayısı (26: çift kayıt iki satır)' "$total / $($expected.Count)" ($total -eq $expected.Count -and $total -eq 26))
Check (Write-DbVerdict 'sayfalar 10, 10, 6' ($sizes -join ', ') (($sizes -join ',') -eq '10,10,6'))
Check (Write-DbVerdict 'sayfaları birleştirince veritabanıyla aynı sıra' "$($got.Count) kayıt" (($got -join ',') -eq ($expected -join ',')))
Check (Write-DbVerdict 'çift kayıtlı numara iki kez listeleniyor' "$(@($got | Where-Object { $_ -eq $numbers[0] }).Count) kez" (@($got | Where-Object { $_ -eq $numbers[0] }).Count -eq 2))

# --- Alanlar ------------------------------------------------------------------------------------------------------------
$item = $first.Json.items[0]
$db = @(Get-ErpRows "SELECT erp_reference, customer_code, amount, currency FROM invoices WHERE invoice_number = '$($item.invoiceNumber)' ORDER BY id LIMIT 1;")[0] -split '\|'
$fieldsOk = $item.erpReference -eq $db[0] -and $item.customerCode -eq $db[1] -and [decimal]$item.amount -eq [decimal]::Parse($db[2], [Globalization.CultureInfo]::InvariantCulture) -and $item.currency -eq $db[3] -and $item.invoiceDate -and $item.receivedAt
Check (Write-DbVerdict 'ilk kaydın alanları veritabanıyla aynı' "$($item.invoiceNumber) $($item.erpReference) $($item.customerCode) $($item.amount) $($item.currency)" ([bool]$fieldsOk))

# --- from dahil, to hariç -----------------------------------------------------------------------------------------------
Write-Step 'Sınırlar: from dahil, to hariç'
$t = $first.ReceivedAt
$one = Get-List $t[0] $t[1] 1 10
Check (Write-DbVerdict 'from = ilk kaydın zamanı, to = ikincinin zamanı: yalnızca ilk kayıt' "$($one.Json.totalCount) kayıt: $(@($one.Json.items | ForEach-Object { $_.invoiceNumber }) -join ', ')" `
    ($one.Json.totalCount -eq 1 -and $one.Json.items[0].invoiceNumber -eq $numbers[0]))
$beyond = Get-List $from $to 9 10
Check (Write-DbVerdict 'aralığın ötesindeki sayfa boş, toplam aynı' "$(@($beyond.Json.items).Count) kayıt, toplam $($beyond.Json.totalCount)" (@($beyond.Json.items).Count -eq 0 -and $beyond.Json.totalCount -eq 26))
$none = Get-List '2000-01-01T00:00:00Z' '2000-01-02T00:00:00Z'
Check (Write-DbVerdict 'kayıt olmayan aralık: 200, boş liste' "$($none.Status), $(@($none.Json.items).Count) kayıt" ($none.Status -eq 200 -and @($none.Json.items).Count -eq 0 -and $none.Json.totalCount -eq 0))

# --- Geçersiz istekler --------------------------------------------------------------------------------------------------
Write-Step 'Geçersiz istekler (400)'
$bad = [ordered]@{
    'pageSize=500 kabul'  = @{ R = (Get-List $from $to 1 500); Expect = 200 }
    'pageSize=501'        = @{ R = (Get-List $from $to 1 501); Expect = 400 }
    'pageSize=0'          = @{ R = (Get-List $from $to 1 0); Expect = 400 }
    'page=0'              = @{ R = (Get-List $from $to 0 10); Expect = 400 }
    'from >= to'          = @{ R = (Get-List $to $from 1 10); Expect = 400 }
}
foreach ($k in $bad.Keys) {
    $ok = $bad[$k].R.Status -eq $bad[$k].Expect
    Check $ok
    Write-Host ('  {0,-20} -> HTTP {1} (beklenen {2})' -f $k, $bad[$k].R.Status, $bad[$k].Expect) -ForegroundColor ($(if ($ok) { 'Gray' } else { 'Red' }))
}
$noFrom = $script:Http.GetAsync("$BaseUrl/api/v1/invoices?to=$([Uri]::EscapeDataString($to))").GetAwaiter().GetResult()
$noTo = $script:Http.GetAsync("$BaseUrl/api/v1/invoices?from=$([Uri]::EscapeDataString($from))").GetAwaiter().GetResult()
Check (Write-DbVerdict 'from ya da to eksik: 400' "$([int]$noFrom.StatusCode), $([int]$noTo.StatusCode)" ([int]$noFrom.StatusCode -eq 400 -and [int]$noTo.StatusCode -eq 400))

Restart-Simulator
Write-Result $allPassed 'liste aralıktaki bütün kayıtları veritabanıyla aynı sırada, sayfa sayfa döndürüyor'
