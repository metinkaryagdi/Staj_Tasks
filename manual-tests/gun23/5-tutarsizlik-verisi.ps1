# Yeniden gönderme tutarsızlığının ekran kontrolü için iki fatura: ikisi de Başarısız, iptalleri ERP kapalıyken Başarısız. Numaraları yazar;
# ekrandaki adımlar elle yapılır. ERP kapalı kalır: bittikten sonra `docker compose up -d erp-simulator`. ~11 dk.
#   .\manual-tests\gun23\5-tutarsizlik-verisi.ps1
. "$PSScriptRoot\_common.ps1"
New-Report 'tutarsizlik-verisi'

Set-Erp @{ ServerError = 100 }
$numbers = @((New-Invoice), (New-Invoice))
foreach ($n in $numbers) { Wait-Until { (Get-InvoiceStatus $n) -eq 'Başarısız' } 480 "$n Başarısız oldu" }

Push-Location $RepoRoot
try { docker compose stop erp-simulator 2>&1 | Out-Null } finally { Pop-Location }
foreach ($n in $numbers) {
    $c = Request-Cancel $n
    if ($c.Status -ne 202) { throw "$n iptal isteği: HTTP $($c.Status)" }
}
foreach ($n in $numbers) { Wait-Until { (Get-Outbox $n 'İptal') -like 'Başarısız|*' } 480 "$n iptali Başarısız oldu" }

Write-Output "FATURALAR=$($numbers -join ',')"
