# İptal: kontrol listesinin 2., 3. ve 4. maddeleri canlı sistemde. Her bölüm simülatörü o maddenin koşuluna göre yeniden
# başlatır (olay sorunları kapalı, karar onay, olaylar 1-2 sn içinde) ve sonucu iki veritabanından okur. TAMAM = beklenen.
#   2) Onaylanmış faturanın iptali ERP'ye ulaşır, ERP'de tek iptal kaydı olur; ikinci iptal isteği 409 alır.
#   3) Fatura tekrar deneme beklerken (ERP her POST'a 500) verilen iptal gönderilmez; ERP düzelip fatura ulaşınca gider.
#   4) İptal gönderilirken (ERP geç cevap veriyor, kaydı önce yapıyor) servis öldürülür ve yeniden açılır: iptal kaybolmaz,
#      ERP'de tek kayıt kalır, tekrar POST edilmez.
# ~6 dk.
#   .\manual-tests\gun22\2-iptal-canli.ps1
param([string]$Etiket = 'b-iptal-canli')
. "$PSScriptRoot\_common.ps1"

New-Report $Etiket
Write-Title 'İptal: kontrol listesi 2, 3, 4'
Start-Stack
Write-Line "Koşu: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

# ---------------------------------------------------------------------------------------------------------------------
Write-Line ''
Write-Line '2) Onaylanmış bir faturanın iptali ERP''ye ulaşıyor ve ERP''de tek bir iptal kaydı var'
Set-Erp @{ Success = 100 }
$n2 = New-Invoice
Write-Line "  Fatura $n2 oluşturuldu"
Wait-Until { (Send-Api GET "/api/v1/invoices/$n2" (Get-UserToken 'operator')).Json.status -eq 'Onaylandı' } 60 "$n2 Onaylandı oldu"
$c1 = Request-Cancel $n2
Check ($c1.Status -eq 202) "Operatörün iptal isteği: HTTP $($c1.Status)"
Wait-Until { (Get-Outbox $n2 'İptal') -like 'Tamamlandı|*' } 60 'İptal satırı Tamamlandı oldu'
$c2 = Request-Cancel $n2
Check ($c2.Status -eq 409 -and $c2.Code -eq 'invoice_cancelled') "Aynı faturaya ikinci iptal isteği: HTTP $($c2.Status) $($c2.Code) - $($c2.Json.detail)"
$erpCount = Get-SqlScalar "SELECT count(*) FROM cancellations WHERE invoice_number = '$n2'"
Check ($erpCount -eq '1') "ERP'de $n2 için iptal kaydı sayısı: $erpCount"
Show-Rows 'ERP veritabanı (cancellations):' "SELECT cancel_reference, invoice_number, to_char(cancelled_at AT TIME ZONE 'Europe/Istanbul', 'HH24:MI:SS.MS') AS iptal_zamani FROM cancellations WHERE invoice_number = '$n2'" -Erp
Show-Rows 'Servis veritabanı (erp_outbox):' "SELECT $OutboxColumns FROM erp_outbox WHERE invoice_number = '$n2' ORDER BY id"
Show-Rows 'Servis veritabanı (operator_actions):' "SELECT operator_name, action, result FROM operator_actions WHERE invoice_number = '$n2' ORDER BY id"
$status2 = (Send-Api GET "/api/v1/invoices/$n2" (Get-UserToken 'operator')).Json.status
Write-Line "  Faturanın servisteki durumu: $status2 (iptal faturanın durumunu değiştirmiyor; ERP'den gelen iptal haberi yarının konusu)"

# ---------------------------------------------------------------------------------------------------------------------
Write-Line ''
Write-Line '3) Fatura tekrar deneme beklerken verilen iptal, fatura ERP''ye ulaşana kadar gönderilmiyor, ulaştıktan sonra gidiyor'
Set-Erp @{ ServerError = 100 }
$n3 = New-Invoice
Write-Line "  Fatura $n3 oluşturuldu; ERP her POST'a 500 dönüyor"
Wait-Until { (Get-Outbox $n3 'Gönderim') -match '^Bekliyor\|[1-9]' } 60 'Faturanın ilk denemesi 500 aldı, tekrar deneme bekliyor'
$c3 = Request-Cancel $n3
Check ($c3.Status -eq 202) "Tekrar deneme beklerken iptal isteği: HTTP $($c3.Status)"
Write-Line '  20 sn boyunca her 5 sn: servisteki satırlar ve ERP''deki kayıtlar'
foreach ($i in 1..4) {
    Start-Sleep -Seconds 5
    Write-Line ("    +{0,2} sn  gönderim={1}  iptal={2}  ERP fatura kaydı={3}  ERP iptal kaydı={4}" -f ($i * 5), (Get-Outbox $n3 'Gönderim'),
        (Get-Outbox $n3 'İptal'), (Get-SqlScalar "SELECT count(*) FROM invoices WHERE invoice_number = '$n3'"),
        (Get-SqlScalar "SELECT count(*) FROM cancellations WHERE invoice_number = '$n3'"))
}
Check ((Get-Outbox $n3 'İptal') -eq 'Bekliyor|0') "Fatura ERP'ye ulaşmadan iptal satırı hiç alınmadı: $(Get-Outbox $n3 'İptal')"
Check ((Get-SqlScalar "SELECT count(*) FROM cancellations WHERE invoice_number = '$n3'") -eq '0') 'ERP''ye iptal gitmedi'
Write-Line '  ERP düzeltiliyor (her POST 202)'
Set-Erp @{ Success = 100 }
Wait-Until { (Get-Outbox $n3 'İptal') -like 'Tamamlandı|*' } 150 'Fatura ulaştı ve iptal satırı Tamamlandı oldu'
$order = Get-SqlScalar "SELECT (SELECT min(received_at) FROM invoices WHERE invoice_number = '$n3') < (SELECT cancelled_at FROM cancellations WHERE invoice_number = '$n3')"
Check ($order -eq 't') "ERP'de faturanın kaydı iptalin kaydından önce: $order"
Show-Rows 'ERP veritabanı (fatura ve iptal kaydı, zamanıyla):' ("SELECT 'fatura' AS kayit, erp_reference AS referans, to_char(received_at AT TIME ZONE 'Europe/Istanbul', 'HH24:MI:SS.MS') AS zaman FROM invoices WHERE invoice_number = '$n3' " +
    "UNION ALL SELECT 'iptal', cancel_reference, to_char(cancelled_at AT TIME ZONE 'Europe/Istanbul', 'HH24:MI:SS.MS') FROM cancellations WHERE invoice_number = '$n3' ORDER BY zaman") -Erp
Show-Rows 'Servis veritabanı (erp_outbox):' "SELECT $OutboxColumns FROM erp_outbox WHERE invoice_number = '$n3' ORDER BY id"

# ---------------------------------------------------------------------------------------------------------------------
Write-Line ''
Write-Line '4) İptal gönderilirken servis öldürülüp yeniden açıldığında iptal kaybolmuyor ve çift işlenmiyor'
$n4 = New-Invoice
Wait-Until { (Get-Outbox $n4 'Gönderim') -like 'Tamamlandı|*' } 60 "$n4 ERP'ye ulaştı"
Set-Erp @{ LateResponse = 100 } @{ 'Simulator__LateResponseDelaySeconds' = 40 }
$c4 = Request-Cancel $n4
Check ($c4.Status -eq 202) "İptal isteği: HTTP $($c4.Status)"
Wait-Until { (Get-SqlScalar "SELECT count(*) FROM cancellations WHERE invoice_number = '$n4'") -eq '1' } 60 'ERP iptali kaydetti, cevabı 40 sn geciktiriyor'
Show-Rows 'Öldürmeden hemen önce (erp_outbox):' "SELECT $OutboxColumns FROM erp_outbox WHERE invoice_number = '$n4' AND kind = 'İptal'"
Push-Location $RepoRoot
try { docker compose kill invoice-service 2>&1 | Out-Null } finally { Pop-Location }
Write-Line "  invoice-service öldürüldü (docker compose kill, SIGKILL) $(Get-Date -Format 'HH:mm:ss')"
# Simülatör yeniden başlatılmaz (logu silinir): yeniden alınan iptal önce GET ile sorar, GET'te hata davranışı yok.
Push-Location $RepoRoot
try { docker compose up -d invoice-service 2>&1 | Out-Null } finally { Pop-Location }
Wait-KeycloakAndService
Write-Line "  invoice-service yeniden açıldı $(Get-Date -Format 'HH:mm:ss'); iptal satırının kilidi (Outbox:LockSeconds = 60) bitince yeniden alınacak"
Wait-Until { (Get-Outbox $n4 'İptal') -like 'Tamamlandı|*' } 150 'İptal satırı Tamamlandı oldu'
$erp4 = Get-SqlScalar "SELECT count(*) FROM cancellations WHERE invoice_number = '$n4'"
Check ($erp4 -eq '1') "ERP'de $n4 için iptal kaydı sayısı: $erp4"
$posts = @(Get-SimulatorLog | Where-Object { $_ -match "ERP cancel (request #\d+ )?invoice=$n4 " })
Write-Line "  ERP logunda $n4 için iptal satırları:"
foreach ($p in $posts) { Write-Line "    $($p -replace '^\S+\s+\S+\s+', '')" }
# ERP'ye ulaşan her iptal isteği bir behavior= satırı yazar: yeni istek "ERP cancel request #N ... behavior=", tekrar gelen istek
# "ERP cancel invoice=... behavior=Duplicate". Geç cevapta aynı isteğin "client disconnected" satırı ayrıca yazılır, sayılmaz.
$draws = @($posts | Where-Object { $_ -match 'ERP cancel (request #\d+ )?invoice=\S+ behavior=' }).Count
Check ($draws -eq 1) "ERP'ye ulaşan iptal isteği (yeni ya da tekrar): $draws (servis açıldıktan sonra ERP'ye sorup iptali buldu, tekrar POST etmedi)"
Show-Rows 'Servis veritabanı (erp_outbox):' "SELECT $OutboxColumns FROM erp_outbox WHERE invoice_number = '$n4' ORDER BY id"
Push-Location $RepoRoot
try { $lines = @(docker compose logs invoice-service --no-log-prefix 2>$null | Where-Object { $_ -match "ERP send.*kind=İptal invoice=$n4" }) } finally { Pop-Location }
Write-Line "  Servisin logunda $n4 iptali (öldürülmeden önce ve yeniden açıldıktan sonra):"
foreach ($l in $lines) { Write-Line "    $($l.Substring(0, [Math]::Min(230, $l.Length)))" }

Save-Report
