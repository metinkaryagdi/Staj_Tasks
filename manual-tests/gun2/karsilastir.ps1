# İki tarafı karşılaştırır: servisteki her fatura simülatörün GET endpoint'iyle sorgulanır ve sayılır.
#   .\manual-tests\gun2\karsilastir.ps1                                  -> servisteki bütün faturalar
#   .\manual-tests\gun2\karsilastir.ps1 -From FTR-000101 -To FTR-000200  -> yalnızca bu aralık
#   -Details: her faturayı tek tek listeler (servis durumu, simülatördeki kayıt sayısı ve referansları)
param([string]$From, [string]$To, [switch]$Details)
. "$PSScriptRoot\_common.ps1"

$range = if ($From -or $To) { "$(if ($From) { $From } else { 'baş' }) .. $(if ($To) { $To } else { 'son' })" } else { 'bütün faturalar' }
Write-Title "Karşılaştırma: Fatura Servisi <-> ERP Simülatörü ($range)"

$c = Compare-Invoices -From $From -To $To
if ($Details) { $c.Details | Format-Table -AutoSize | Out-Host }
