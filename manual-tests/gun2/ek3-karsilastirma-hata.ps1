# Gün 2 - Ek test 3 (QA bulgusu 3'ün düzeltmesi): karşılaştırma script'i yalnızca 404'ü "simülatörde yok" saymalı.
# Simülatörün GET'i 500 dönerse ya da simülatöre hiç ulaşılamazsa, faturanın ERP'de olup olmadığı bilinmez:
# fatura "var"/"yok" sayılmamalı, "sorgulanamadı" satırına yazılmalı.
# Düzeltmeden önce bu durumda ERP'de kayıtlı faturalar da "simülatörde yok" sayılıyordu.
#
# Aynı fatura aralığı üç kez karşılaştırılır:
#   A) Gerçek simülatör             -> sorgulanamadı 0; sonuç iki veritabanından hesaplananla aynı
#   B) Her GET'e 500 dönen sahte ERP -> hepsi sorgulanamadı, hiçbiri "yok" değil
#   C) Simülatör durdurulmuş          -> hepsi sorgulanamadı (bağlantı hatası), hiçbiri "yok" değil
# Uygulamalara dokunulmaz; B'de yalnızca script'in simülatör adresi geçici olarak sahte ERP'ye yönlendirilir.
param([int]$Count = 6)
. "$PSScriptRoot\_common.ps1"
. "$PSScriptRoot\_fake-erp.ps1"

Write-Title "Ek 3) Karşılaştırma script'i: 404 dışındaki cevaplar 'simülatörde yok' sayılmıyor"
Wait-Service

$numbers = @(Get-ServiceRows "SELECT invoice_number FROM invoices ORDER BY invoice_number DESC LIMIT $Count;")
if ($numbers.Count -eq 0) { throw 'Serviste fatura yok; önce bir kaç fatura oluşturun (ör. 2-hata-yok.ps1 -Count 10).' }
$from = $numbers[-1]; $to = $numbers[0]
$n = $numbers.Count
$realUrl = $SimulatorUrl
$db = Get-DbComparison $from $to
Write-Host "  Fatura aralığı: $from .. $to ($n fatura)"
Write-Host "  İki veritabanından hesaplanan gerçek durum: $(Format-Comparison $db)" -ForegroundColor DarkGray

function Test-NothingMissing($c, [string]$Case) {
    $missing = $c.SentMissing + $c.FailedMissing
    Write-DbVerdict "$Case`: $n fatura sorgulanamadı, hiçbiri 'simülatörde yok' sayılmadı" `
        "sorgulanamadı $($c.Unknown), 'yok' sayılan $missing, 'var' sayılan $($c.SentFound + $c.FailedFound)" `
        ($c.Unknown -eq $n -and $missing -eq 0 -and $c.SentFound + $c.FailedFound -eq 0)
}

# ---------------------------------------------------------------- A
Write-Step 'A) Gerçek simülatörle karşılaştırma'
$a = Compare-Invoices -From $from -To $to
Write-Host ''
$okA = Write-DbVerdict "A: sorgulanamadı 0; sonuç veritabanlarından hesaplananla aynı ($(Format-Comparison $db))" `
    (Format-Comparison $a) ((Format-Comparison $a) -eq (Format-Comparison $db))

# ---------------------------------------------------------------- B
Write-Step 'B) Her GET isteğine 500 dönen sahte ERP ile karşılaştırma'
$fake = Start-FakeErp -StatusCode 500
try {
    $SimulatorUrl = $fake.Url
    Write-Host "  Script'in simülatör adresi geçici olarak: $SimulatorUrl"
    $b = Compare-Invoices -From $from -To $to
}
finally {
    Stop-FakeErp $fake
    $SimulatorUrl = $realUrl
}
Write-Host ''
$okB = Test-NothingMissing $b 'B'

# ---------------------------------------------------------------- C
Write-Step 'C) Simülatör durdurulmuşken karşılaştırma'
try {
    Invoke-Compose @('stop', 'erp-simulator')
    Write-Host '  docker compose stop erp-simulator (erp-db açık kalır)'
    $c = Compare-Invoices -From $from -To $to
}
finally {
    Restart-Simulator
}
Write-Host ''
$okC = Test-NothingMissing $c 'C'

# ---------------------------------------------------------------- veritabanı
Write-DbHeader "Ek 3: aralıktaki faturaların iki taraftaki gerçek hali" "Fatura aralığı: $from .. $to"
$range = "invoice_number BETWEEN '$from' AND '$to'"
Show-ServiceQuery "SELECT invoice_number, status, erp_reference, send_attempt_count FROM invoices WHERE $range ORDER BY 1;"
Show-ErpQuery ("SELECT invoice_number, count(*) AS kayit, string_agg(erp_reference || ' ' || behavior, ', ' ORDER BY id) AS kayitlar " +
    "FROM invoices WHERE $range GROUP BY 1 ORDER BY 1;")
Write-Host '  (B ve C sırasında bu kayıtlar ERP''de duruyordu; script onları "yok" saysaydı yanlış olurdu.)' -ForegroundColor DarkGray
Write-Host ''
$erpInvoices = [int]@(Get-ErpRows "SELECT count(DISTINCT invoice_number) FROM invoices WHERE $range;")[0]
$okDb = Write-DbVerdict "A'nın 'var' sayısı = veritabanında ERP kaydı olan fatura sayısı" `
    "A'da 'var' $($a.SentFound + $a.FailedFound), veritabanında $erpInvoices" ($a.SentFound + $a.FailedFound -eq $erpInvoices)

Write-Result ($okA -and $okB -and $okC -and $okDb) ("A: sorgulanamadı $($a.Unknown); B (500): sorgulanamadı $($b.Unknown), yok $($b.SentMissing + $b.FailedMissing); " +
    "C (kapalı): sorgulanamadı $($c.Unknown), yok $($c.SentMissing + $c.FailedMissing); veritabanı kontrolü: $(if ($okDb) { 'geçti' } else { 'KALDI' })")
