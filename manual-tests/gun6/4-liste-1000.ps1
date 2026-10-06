# Gün 6 - Madde 4: fatura listesinde durum filtresi, arama ve sayfalama doğru çalışıyor mu. ~1 dk.
#
#   Veritabanındaki bütün faturalar üzerinde (1000 faturalık testten sonra en az bu kadar) sayfa sayfa okunur ve veritabanının
#   sıralamasıyla (en yeni üstte) karşılaştırılır: hiçbir fatura atlanmıyor, tekrarlanmıyor; durum filtresi her durum için aynı sayıyı
#   ve aynı faturaları veriyor; arama numaranın bir parçasıyla (büyük/küçük harf fark etmez) veritabanındaki ILIKE ile aynı sonucu veriyor.
#   Kayıt eklemez, hiçbir şeyi değiştirmez. Önce 3-ozet-1000.ps1 ile 1000 fatura gönderilmiş olmalı.
. "$PSScriptRoot\_common.ps1"

Write-Title 'Madde 4) Fatura listesi: durum filtresi, arama, sayfalama'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service
$order = 'ORDER BY created_at DESC, invoice_number DESC'

# Bir süzgeçle bütün sayfaları okur; numaraları sırayla döner.
function Read-AllPages([string]$Filter, [int]$PageSize) {
    $numbers = @(); $page = 1
    do {
        $r = Get-Api "/api/v1/invoices?page=$page&pageSize=$PageSize$Filter"
        if ($r.Status -ne 200) { throw "Sayfa $page -> $($r.Status): $($r.Body)" }
        $numbers += @($r.Json.items | ForEach-Object { $_.invoiceNumber })
        $page++
    } while ($page -le $r.Json.totalPages)
    $numbers
}

# --- A) Süzgeçsiz: bütün sayfalar ----------------------------------------------------------------------------------
Write-DbHeader 'Fatura Servisi' 'A) Süzgeçsiz liste, 100''erli sayfalar: sıra ve eksiksizlik'
$dbAll = @(Get-ServiceRows "SELECT invoice_number FROM invoices $order;")
$apiAll = Read-AllPages '' 100
$dupes = $apiAll.Count - @($apiAll | Select-Object -Unique).Count
Show-ServiceQuery "SELECT count(*) AS toplam FROM invoices;"
Check (Write-DbVerdict "$($dbAll.Count) fatura, aynı sırada" "$($apiAll.Count) fatura, $dupes tekrar" `
    ($apiAll.Count -eq $dbAll.Count -and $dupes -eq 0 -and ($apiAll -join ',') -eq ($dbAll -join ',')))

# --- B) Sayfa boyutu ve sayfa numarası ------------------------------------------------------------------------------
Write-DbHeader 'Fatura Servisi' 'B) Sayfa boyutu 20: 3. sayfa = sıralamada 41-60. faturalar'
$page3 = Get-Api '/api/v1/invoices?page=3&pageSize=20'
$expected = @($dbAll[40..59])
Check (Write-DbVerdict "3. sayfa: $($expected[0]) .. $($expected[-1]); $([math]::Ceiling($dbAll.Count / 20)) sayfa" `
    "$($page3.Json.items[0].invoiceNumber) .. $($page3.Json.items[-1].invoiceNumber); $($page3.Json.totalPages) sayfa" `
    ((@($page3.Json.items | ForEach-Object { $_.invoiceNumber }) -join ',') -eq ($expected -join ',') -and $page3.Json.totalPages -eq [math]::Ceiling($dbAll.Count / 20)))

# --- C) Durum filtresi ----------------------------------------------------------------------------------------------
Write-DbHeader 'Fatura Servisi' 'C) Durum filtresi: her durum için sayı ve fatura listesi'
Show-ServiceQuery "SELECT status, count(*) FROM invoices GROUP BY status ORDER BY status;"
foreach ($status in @('Bekliyor', 'Gönderildi', 'İşleme Alındı', 'Onaylandı', 'Reddedildi', 'Başarısız')) {
    $dbNumbers = @(Get-ServiceRows "SELECT invoice_number FROM invoices WHERE status = '$status' $order;")
    $apiNumbers = Read-AllPages "&status=$([Uri]::EscapeDataString($status))" 100
    Check (Write-DbVerdict "$status : $($dbNumbers.Count) fatura, aynı sırada" "$($apiNumbers.Count) fatura" `
        ($apiNumbers.Count -eq $dbNumbers.Count -and ($apiNumbers -join ',') -eq ($dbNumbers -join ',')))
}

# --- D) Arama ------------------------------------------------------------------------------------------------------
Write-DbHeader 'Fatura Servisi' 'D) Arama: numaranın bir parçası, büyük/küçük harf fark etmez, durumla birlikte'
$newest = $dbAll[0]
$terms = @($newest, ($newest -replace '^FTR-', '').TrimStart('0'), $newest.Substring(0, $newest.Length - 2), $newest.ToLower(), 'FTR-0000', 'yok-boyle-numara')
foreach ($term in $terms) {
    $dbCount = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE invoice_number ILIKE '%$term%';")[0]
    $r = Get-Api "/api/v1/invoices?search=$([Uri]::EscapeDataString($term))&pageSize=1"
    Check (Write-DbVerdict "arama '$term': $dbCount fatura" "$($r.Json.totalCount)" ($r.Json.totalCount -eq $dbCount))
}
$both = Get-Api "/api/v1/invoices?search=FTR-0&status=$([Uri]::EscapeDataString('Başarısız'))&pageSize=1"
$dbBoth = [int]@(Get-ServiceRows "SELECT count(*) FROM invoices WHERE invoice_number ILIKE '%FTR-0%' AND status = 'Başarısız';")[0]
Check (Write-DbVerdict "arama 'FTR-0' + durum Başarısız: $dbBoth fatura" "$($both.Json.totalCount)" ($both.Json.totalCount -eq $dbBoth))

Write-Result $allPassed 'durum filtresi, arama ve sayfalama veritabanıyla aynı sonucu veriyor'
