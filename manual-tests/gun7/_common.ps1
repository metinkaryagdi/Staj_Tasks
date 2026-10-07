# Gün 7 script'lerinin ortak yardımcıları. Gün 6'nın _common.ps1'ini de yükler (Gün 1-5 yardımcıları dahil). Doğrudan
# çalıştırılmaz.
. "$PSScriptRoot\..\gun6\_common.ps1"

# Takılı faturalar veritabanında: Gönderildi ya da İşleme Alındı'da özetteki süreden uzun kalmış olanlar.
function Get-StuckSql([int]$Minutes, [string]$Select = 'invoice_number') {
    "SELECT $Select FROM invoices WHERE status IN ('Gönderildi','İşleme Alındı') AND updated_at < now() - interval '$Minutes minutes'"
}

# GET /invoices?stuck=true'nun bütün sayfalarındaki fatura numaraları (sıralı) ve cevaptaki toplam.
function Get-StuckList([string]$Extra = '') {
    $numbers = @(); $page = 1; $total = 0
    do {
        $r = Get-Api "/api/v1/invoices?stuck=true&pageSize=100&page=$page$Extra"
        if ($r.Status -ne 200) { throw "stuck=true listesi HTTP $($r.Status): $($r.Body)" }
        $numbers += @($r.Json.items | ForEach-Object { $_.invoiceNumber })
        $total = $r.Json.totalCount
        $page++
    } while ($page -le $r.Json.totalPages)
    [pscustomobject]@{ Numbers = @($numbers | Sort-Object); Total = $total }
}

# Başlığı kendimiz yöneten ayrı istemci: ortak istemci her isteğe 'X-Operator-Name: test-script' ekler.
Add-Type -AssemblyName System.Net.Http
$script:BareHttp = New-Object System.Net.Http.HttpClient
$script:BareHttp.Timeout = [TimeSpan]::FromMinutes(2)

# Fatura Servisi'ne POST: $Name $null ise başlık hiç gönderilmez, verilirse ekranın yaptığı gibi yüzde kodlanarak
# (encodeURIComponent) gönderilir; -Raw ile olduğu gibi. Post-Api ile aynı biçimde döner.
function Send-OperatorPost([string]$Path, [string]$Json = $null, $Name = $null, [switch]$Raw) {
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, "$ServiceUrl$Path")
    if ($null -ne $Json) { $request.Content = [Net.Http.StringContent]::new($Json, [Text.Encoding]::UTF8, 'application/json') }
    if ($null -ne $Name) {
        $value = if ($Raw) { $Name } else { [Uri]::EscapeDataString($Name) }
        $request.Headers.TryAddWithoutValidation('X-Operator-Name', $value) | Out-Null
    }
    Receive-Api ($script:BareHttp.SendAsync($request))
}

# operator_actions'ın en büyük id'si; bir adımdan sonra yalnızca o adımın yazdıklarına bakmak için.
function Get-LastActionId { [long]@(Get-ServiceRows 'SELECT coalesce(max(id), 0) FROM operator_actions;')[0] }

# Mutabakat çalışmasının servis logundaki ERP satırları: verilen faturaların sorgu satırları ve çalışmanın özet satırı.
function Get-RunLookups([long]$RunId, [string[]]$Numbers) {
    $invoices = ($Numbers | ForEach-Object { [regex]::Escape($_) }) -join '|'
    @(foreach ($c in @(docker ps --format '{{.Names}}' | Where-Object { $_ -match 'invoice-service' })) {
        docker logs --since 10m $c 2>&1 | ForEach-Object { "$_" } |
            Where-Object { $_ -match "Reconciliation asked the ERP run=$RunId invoice=($invoices) " -or $_ -match "Reconciliation ERP lookups run=$RunId " }
    })
}

# 3 gün önce oluşturulmuş, ERP'den "Kayıt yok" cevabı $CheckedAgo önce alınmış Başarısız fatura ekler; numarasını döner.
function New-NotFoundInvoice([string]$CustomerCode, [string]$CheckedAgo) {
    @(Get-ServiceRows ("INSERT INTO invoices (invoice_number, customer_code, amount, currency, invoice_date, status, last_error, " +
        "send_attempt_count, created_at, updated_at, erp_checked_at, erp_check_result) " +
        "SELECT 'FTR-' || lpad(nextval('invoice_number_seq')::text, 6, '0'), '$CustomerCode', 100.00, 'TRY', current_date - 3, 'Başarısız', " +
        "'elle eklendi: ERP hiç almadı', 10, now() - interval '3 days', now() - interval '3 days', now() - interval '$CheckedAgo', 'Kayıt yok' " +
        "RETURNING invoice_number;") | Where-Object { $_ -match '^FTR-' })[0]
}

function Show-ErpCheck([string[]]$Numbers) {
    Show-ServiceQuery ("SELECT invoice_number, status, to_char(updated_at,'MM-DD HH24:MI:SS') AS guncellendi, " +
        "to_char(erp_checked_at,'MM-DD HH24:MI:SS') AS erp_son_soru, erp_check_result, " +
        "date_trunc('second', now() - erp_checked_at) AS soru_uzerinden_gecen FROM invoices WHERE invoice_number IN ($(InList $Numbers)) ORDER BY 1;")
}

# Fatura Servisi kapsayıcısındaki ortam değişkeni; yoksa ayar dosyasındaki değer geçerlidir.
function Get-ServiceEnv([string]$Key) {
    $value = docker exec staj-tasks-invoice-service-1 sh -c "printenv $Key || true"
    if ($value) { "$Key=$value" } else { "$Key yok (appsettings.json)" }
}
