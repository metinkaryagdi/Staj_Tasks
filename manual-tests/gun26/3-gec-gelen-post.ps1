# Kontrol listesi 6 (seed 2'de bulunan hata): ağ koptuğunda servisin vazgeçtiği POST, ağ geri gelince geç ulaşıp ERP'de çift fatura
# oluşturuyor mu. Boş veritabanıyla, tek kopya, simülatör hatasız (Success 100), yüzde 0 (v1: aynı numarayı yeniden kaydeder).
# Önce birkaç fatura gönderilir: servisin ERP'ye açık bağlantıları olsun. Sonra simülatör apps ağından çıkarılır, faturalar
# oluşturulur (ilk POST'ları açık bağlantılardan gider ama cevap gelmez, 10 sn'de zaman aşımı), -ReconnectAfterSeconds sonra ağ
# geri bağlanır. Kuyruk boşalınca ERP'deki kayıtlar sayılır. Çıktı manual-tests\output\gun26\<-Etiket>.txt.
#   .\manual-tests\gun26\3-gec-gelen-post.ps1 -Etiket c-gec-gelen-post-once
param([string]$Etiket = 'c-gec-gelen-post', [int]$WarmUp = 10, [int]$Count = 10, [int]$ReconnectAfterSeconds = 30)
. "$PSScriptRoot\_common.ps1"
Use-Gun10Volumes "gun26-gecpost-$(Get-Date -Format 'MMddHHmm')"
New-Report $Etiket
Write-Title 'Ağ koptuğunda vazgeçilen POST: ERP''de çift fatura'
Write-Line "Koşu: $(Get-Date -Format 'yyyy-MM-dd HH:mm'), ısınma $WarmUp fatura, ağ kopukken $Count fatura, ağ $ReconnectAfterSeconds sn sonra geri"
Push-Location $RepoRoot
try { docker compose --profile iki-kopya down --remove-orphans 2>&1 | Out-Null } finally { Pop-Location }
Start-Stack
Set-Erp @{ Success = 100 }
$since = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

function New-Many([int]$N) {
    $token = Get-OrderSystemToken
    1..$N | ForEach-Object {
        $r = Send-Api POST '/api/v1/invoices' $token '{"customerCode":"C-026","amount":125.50,"currency":"TRY","invoiceDate":"2026-11-09"}'
        if ($r.Status -ne 202) { throw "Fatura oluşturulamadı: HTTP $($r.Status)" }
        $r.Json.invoiceNumber
    }
}

Write-Line ''
Write-Line '1) Isınma: servisin ERP''ye açık bağlantıları olsun'
$warm = @(New-Many $WarmUp)
Wait-Until { [int](Invoke-InvoiceSql "SELECT count(*) FROM erp_outbox WHERE status = 'Bekliyor'") -eq 0 } 120 'Isınma faturaları gönderildi'

Write-Line ''
Write-Line '2) Simülatör apps ağından çıkarılıyor, faturalar oluşturuluyor'
Push-Location $RepoRoot
try { $erpId = (docker compose ps -q erp-simulator | Select-Object -First 1).Trim() } finally { Pop-Location }
docker network disconnect staj-tasks_apps $erpId 2>&1 | Out-Null
$cutAt = Get-Date
$numbers = @(New-Many $Count)
Write-Line "  Ağ koptu $($cutAt.ToString('HH:mm:ss')); faturalar: $($numbers[0]) ... $($numbers[-1])"
Start-Sleep -Seconds ([Math]::Max(0, $ReconnectAfterSeconds - ((Get-Date) - $cutAt).TotalSeconds))
docker network connect --alias erp-simulator staj-tasks_apps $erpId 2>&1 | Out-Null
Write-Line "  Ağ geri bağlandı $((Get-Date).ToString('HH:mm:ss'))"

Write-Line ''
Write-Line '3) Kuyruk boşalıyor; TCP''nin geç tekrar göndermeleri için 3 dk daha bekleniyor'
Wait-Until { [int](Invoke-InvoiceSql "SELECT count(*) FROM erp_outbox WHERE status = 'Bekliyor'") -eq 0 } 600 'Kuyruk boşaldı'
Start-Sleep -Seconds 180

$list = ($numbers | ForEach-Object { "'$_'" }) -join ','
Show-Rows 'Servis (invoices):' "SELECT invoice_number, status, erp_reference, send_attempt_count AS deneme FROM invoices WHERE invoice_number IN ($list) ORDER BY 1"
Show-Rows 'ERP (kayıt sayısı):' "SELECT invoice_number, count(*) AS kayit, string_agg(erp_reference || ' ' || to_char(received_at AT TIME ZONE 'Europe/Istanbul', 'HH24:MI:SS.MS'), ', ' ORDER BY received_at) AS kayitlar FROM invoices WHERE invoice_number IN ($list) GROUP BY 1 ORDER BY 1" -Erp
$dup = [int](Get-SqlScalar "SELECT count(*) FROM (SELECT invoice_number FROM invoices WHERE invoice_number IN ($list) GROUP BY 1 HAVING count(*) > 1) d")
Push-Location $RepoRoot
try {
    $posts = @(docker compose logs --no-color --no-log-prefix --since $since erp-simulator 2>&1 | ForEach-Object { "$_" } |
        Where-Object { $_ -match 'ERP request #\d+ invoice=(FTR-\d+) behavior=' -and $numbers -contains $Matches[1] })
}
finally { Pop-Location }
Write-Line "  Simülatörün aldığı POST (bu faturalar): $($posts.Count)"
foreach ($p in $posts) { Write-Line "    $(($p -replace ' trace_id=.*$', ''))" }
Check ($dup -eq 0) "ERP'de birden fazla kaydı olan fatura: $dup / $($numbers.Count)"
Save-Report
