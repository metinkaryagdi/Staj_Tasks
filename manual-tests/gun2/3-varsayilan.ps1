# Gün 2 - Madde 3: Varsayılan oranlar ve seed 42 ile 100 fatura, sonra karşılaştırma tablosu.
# Simülatör yeniden oluşturulur, böylece seed 42 dizisi en baştan başlar. Geç cevaplar yüzünden ~2-3 dk sürer.
# Fatura aralığı output\gun2-3.json'a yazılır; 4-yeniden-gonder.ps1 aynı faturaları kullanır.
param([int]$Count = 100)
. "$PSScriptRoot\_common.ps1"

Write-Title "3) Varsayılan oranlar, seed 42, $Count fatura -> karşılaştırma tablosu"

Restart-Simulator @{ Simulator__Seed = 42 }
Wait-Service

Write-Step "$Count fatura Fatura Servisi'ne gönderiliyor (geç cevaplarda servis 10 sn bekleyip Başarısız yazar)"
$results = foreach ($i in 1..$Count) { $r = New-ServiceInvoice; Write-ServiceResult $r; $r }
$from = $results[0].InvoiceNumber
$to = $results[-1].InvoiceNumber
Save-Range 'gun2-3' $from $to

Write-Step 'Simülatörün seçtiği davranış -> servisteki durum (simülatör logundan)'
$behaviors = Get-SimulatorBehaviors
$results | Group-Object { ($behaviors[$_.InvoiceNumber] -join ',') + ' -> ' + $_.Status } |
    Sort-Object Count -Descending | ForEach-Object { Write-Host ('  {0,-40} {1,4}' -f $_.Name, $_.Count) }

Write-Step "Karşılaştırma ($from .. $to)"
$c = Compare-Invoices -From $from -To $to

Write-Result ($c.Total -eq $Count -and $c.SentMissing -eq 0) `
    "Gönderildi+var: $($c.SentFound), Başarısız+yok: $($c.FailedMissing), Başarısız+var: $($c.FailedFound)"
Write-Host "  Aralık kaydedildi: $from .. $to  (sonraki adım: .\manual-tests\gun2\4-yeniden-gonder.ps1)" -ForegroundColor DarkGray
