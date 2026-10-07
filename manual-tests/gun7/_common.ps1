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
