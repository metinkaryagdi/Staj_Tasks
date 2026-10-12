# Tek kopyayla yük testi, ardından önce/sonra tablosunun ölçümü (2-yuk-olcum.ps1). Önce ve sonra aynı koşullarla çalıştırılır:
#   .\manual-tests\gun10\1-yuk-testi.ps1 -Label once -Volume once
# Yığın -Volume ile verilen BOŞ volume'lerde ayakta olmalı (veritabanında fatura varsa durur). Simülatör appsettings.json'daki
# seed ile yeniden başlatılır (seed'li dizi baştan başlar); Fatura Servisi tek kopya çalışır. Yük: saniyede 50 fatura, 5 dakika
# (load-test/invoices.js varsayılanı, Gün 8'in tek kopya koşusuyla aynı).
param(
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][string]$Volume,
    [int]$Rate = 50,
    [string]$Duration = '5m'
)

. "$PSScriptRoot\_common.ps1"
Use-Gun10Volumes $Volume

Write-Title "Yük testi: tek kopya, $Label"

$existing = [int]@(Get-ServiceRows 'SELECT count(*) FROM invoices;')[0]
if ($existing -ne 0) { throw "Fatura veritabanı boş değil ($existing fatura): koşu boş volume ile başlamalı." }
$second = @(docker ps --format '{{.Names}}' | Where-Object { $_ -match 'invoice-service-2' })
if ($second.Count -gt 0) { throw 'İkinci kopya çalışıyor; bu ölçüm tek kopyayla yapılır.' }

Restart-Simulator
Restart-InvoiceService

$runId = "GUN10-$Label-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
Write-Step "Yük testi (load-test/invoices.js): saniyede $Rate fatura, $Duration (müşteri kodu $runId)"
Invoke-LoadTest @{ BASE_URLS = 'http://invoice-service:8080'; RATE = $Rate; DURATION = $Duration; RUN_ID = $runId } | Out-Null

& "$PSScriptRoot\2-yuk-olcum.ps1" -RunId $runId -Label $Label -Volume $Volume
