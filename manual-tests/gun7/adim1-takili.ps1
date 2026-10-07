# Gün 7 - Adım 1: fatura listesinde "Takılı" süzgeci (GET /invoices?stuck=true). ~1 dk.
#
#   3 yeni fatura veritabanında 10 dk önce Gönderildi'ye alınır (takılı), 1 fatura az önce Gönderildi'ye alınır (takılı
#   değil). Sonra listedeki takılı faturalar, cevaptaki toplam, özetteki takılı sayısı ve veritabanı aynı ana denk gelen
#   okumalarla karşılaştırılır.
#
# Önce servisin yeni kodla derlenmiş olması gerekir: docker compose up -d --build invoice-service
# Oluşturulan 3 takılı fatura öyle kalır; mutabakatın bir sonraki çalışması ERP'nin kararını uygulayıp düzeltir.
. "$PSScriptRoot\_common.ps1"

Write-Title 'Adım 1) Fatura listesinde Takılı süzgeci = özetteki takılı sayısı = veritabanı'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service

$numbers = @(New-Invoices 4)
$stuck = $numbers[0..2]; $fresh = $numbers[3]
Wait-InvoicesIn $numbers @('Onaylandı', 'Reddedildi') 180 'kesin durumda' | Out-Null
Wait-EventsDone $numbers 120 | Out-Null

Write-Step "$($stuck -join ', ') 10 dk önce Gönderildi'ye alınıyor (takılı); $fresh şimdi Gönderildi'ye alınıyor (takılı değil)"
# SQL argüman olarak verilir (stdin PowerShell 5.1'de Türkçe karakterleri bozar).
Invoke-ServiceSql ("UPDATE invoices SET status = 'Gönderildi', reject_reason = NULL, updated_at = now() - interval '10 minutes' WHERE invoice_number IN ($(InList $stuck)); " +
                   "UPDATE invoices SET status = 'Gönderildi', reject_reason = NULL, updated_at = now() WHERE invoice_number = '$fresh';") | Out-Null
Show-ServiceQuery "SELECT invoice_number, status, to_char(updated_at, 'HH24:MI:SS') AS son_guncelleme FROM invoices WHERE invoice_number IN ($(InList $numbers)) ORDER BY 1;"

$minutes = (Get-Api '/api/v1/invoices/summary').Json.stuckAfterMinutes
Write-Host "  takılı sayılma süresi (Reconciliation:StuckAfterMinutes): $minutes dk"

# --- A) Liste = özet = veritabanı ---------------------------------------------------------------------------------
Write-DbHeader 'Fatura Servisi' 'A) Takılı süzgeci: listedeki faturalar ve sayı, özetteki sayı, veritabanı'
Show-ServiceQuery ((Get-StuckSql $minutes 'invoice_number, status, updated_at') + ' ORDER BY 1;')
# Bir fatura iki okuma arasında süreyi geçip takılı olabilir: veritabanı listeden önce ve sonra aynı çıkana kadar tekrar edilir.
for ($i = 0; $i -lt 30; $i++) {
    $before = @(Get-ServiceRows ((Get-StuckSql $minutes) + ' ORDER BY 1;'))
    $list = Get-StuckList
    $summary = (Get-Api '/api/v1/invoices/summary').Json
    $after = @(Get-ServiceRows ((Get-StuckSql $minutes) + ' ORDER BY 1;'))
    if (($before -join ',') -eq ($after -join ',')) { break }
    Start-Sleep -Seconds 1
}
$db = @($after | Sort-Object)
Check (Write-DbVerdict "veritabanında $($db.Count) takılı fatura" "liste toplamı $($list.Total), listedeki satır $($list.Numbers.Count), özet $($summary.stuckCount)" `
    ($list.Total -eq $db.Count -and $list.Numbers.Count -eq $db.Count -and $summary.stuckCount -eq $db.Count))
Check (Write-DbVerdict 'listedeki numaralar = veritabanındaki numaralar' $(if (($list.Numbers -join ',') -eq ($db -join ',')) { 'aynı' } else { "farklı: liste [$($list.Numbers -join ', ')]" }) `
    (($list.Numbers -join ',') -eq ($db -join ',')))

$inList = @($stuck | Where-Object { $list.Numbers -contains $_ })
Check (Write-DbVerdict "10 dk önce Gönderildi olan 3 fatura listede" "$($inList.Count) tanesi listede" ($inList.Count -eq 3))
Check (Write-DbVerdict "az önce Gönderildi olan $fresh listede değil" $(if ($list.Numbers -contains $fresh) { 'listede' } else { 'listede değil' }) `
    (-not ($list.Numbers -contains $fresh)))

# --- B) Diğer süzgeçlerle birlikte ve geçersiz değer ---------------------------------------------------------------
Write-DbHeader 'Fatura Servisi' 'B) Takılı + durum, takılı + arama; geçersiz stuck değeri'
$dbSent = Count-Service ((Get-StuckSql $minutes 'count(*)') + " AND status = 'Gönderildi';")
$sent = Get-Api "/api/v1/invoices?stuck=true&pageSize=1&status=$([Uri]::EscapeDataString('Gönderildi'))"
Check (Write-DbVerdict "takılı ve Gönderildi: $dbSent" "$($sent.Json.totalCount)" ($sent.Json.totalCount -eq $dbSent))

$searched = Get-Api "/api/v1/invoices?stuck=true&search=$($stuck[0])"
Check (Write-DbVerdict "takılı ve '$($stuck[0])' araması: 1 fatura" "$($searched.Json.totalCount)" ($searched.Json.totalCount -eq 1))
$freshSearched = Get-Api "/api/v1/invoices?stuck=true&search=$fresh"
Check (Write-DbVerdict "takılı ve '$fresh' araması: 0 fatura" "$($freshSearched.Json.totalCount)" ($freshSearched.Json.totalCount -eq 0))

$all = Get-Api '/api/v1/invoices?pageSize=1'
$notStuck = Get-Api '/api/v1/invoices?pageSize=1&stuck=false'
$bad = Get-Api '/api/v1/invoices?stuck=evet'
Check (Write-DbVerdict "stuck=false süzmez (toplam $($all.Json.totalCount)); stuck=evet: 400" "$($notStuck.Json.totalCount); $($bad.Status)" `
    ($notStuck.Json.totalCount -eq $all.Json.totalCount -and $bad.Status -eq 400))

Write-Host ''
Write-Host "Ekranda: http://localhost:5100 Özet → Takılı fatura kartı → liste Takılı süzgeciyle açılır; sayı $($summary.stuckCount) civarı olmalı."
Write-Result $allPassed 'Adım 1'
