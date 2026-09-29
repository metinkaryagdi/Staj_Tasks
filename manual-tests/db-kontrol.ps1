# Testleri tekrar çalıştırmadan, her testin EN SON çalıştırmasını veritabanında kontrol eder.
# Test script'lerinin sonundaki "VERİTABANI KONTROLÜ" bölümüyle aynı kontrolleri yapar.
#   .\manual-tests\db-kontrol.ps1          -> 7 testin hepsi
#   .\manual-tests\db-kontrol.ps1 -Test 3  -> sadece test 3
param([ValidateRange(0, 7)][int]$Test = 0)
. "$PSScriptRoot\_common.ps1"

# Test script'lerinin ürettiği numaralar: T1-20260929-131638-7, T5-20260929-131931-DUP, T6-20260929-131948-A-7
function Get-LatestPrefix([int]$Number) {
    Get-SqlScalar ("SELECT substring(invoice_number from '^T$Number-[0-9]{8}-[0-9]{6}-') FROM invoices " +
        "WHERE invoice_number ~ '^T$Number-[0-9]{8}-[0-9]{6}-' ORDER BY id DESC LIMIT 1;")
}

# Kaç fatura gönderildiği: en büyük sıra numarası (T1-...-100 -> 100).
function Get-SentCount([string]$Prefix) {
    [int](Get-SqlScalar "SELECT max(split_part(invoice_number, '-', 4)::int) FROM invoices WHERE invoice_number LIKE '$Prefix%';")
}

function Write-NotRun([int]$Number, [string]$Script) {
    Write-DbHeader "Test $Number"
    Write-Host "  Bu test henüz çalıştırılmamış. Önce .\manual-tests\$Script çalıştırın." -ForegroundColor Yellow
    $false
}

$results = [ordered]@{}
$tests = if ($Test -eq 0) { 1..7 } else { @($Test) }

foreach ($number in $tests) {
    switch ($number) {
        1 {
            $prefix = Get-LatestPrefix 1
            $results['1'] = if (-not $prefix) { Write-NotRun 1 '1-hata-yok.ps1' } else {
                $count = Get-SentCount $prefix
                Test-DbAllSaved -Title "Test 1: $count kayıt, hepsi Success" -Prefix $prefix -Count $count -Behavior 'Success'
            }
        }
        2 {
            # Meşgul testinde hiçbir şey kaydedilmediği için "son çalıştırma" veritabanından bulunamaz;
            # şimdiye kadarki bütün T2 çalıştırmaları birlikte kontrol edilir.
            $results['2'] = Test-DbNoneSaved -Title 'Test 2: hiç kayıt olmamalı (bütün T2 çalıştırmaları)' -Prefix 'T2-'
        }
        3 {
            $prefix = Get-LatestPrefix 3
            $results['3'] = if (-not $prefix) { Write-NotRun 3 '3-kaydet-hata.ps1' } else {
                $count = Get-SentCount $prefix
                Test-DbAllSaved -Title "Test 3: 500 dönen $count faturanın hepsi kayıtlı" -Prefix $prefix -Count $count -Behavior 'SaveThenError'
            }
        }
        4 {
            $prefix = Get-LatestPrefix 4
            $results['4'] = if (-not $prefix) { Write-NotRun 4 '4-gec-cevap.ps1' } else {
                $count = Get-SentCount $prefix
                Test-DbAllSaved -Title "Test 4: geç cevap verilen $count faturanın hepsi kayıtlı" -Prefix $prefix -Count $count -Behavior 'LateResponse' -ShowRows
            }
        }
        5 {
            $prefix = Get-LatestPrefix 5
            $results['5'] = if (-not $prefix) { Write-NotRun 5 '5-cift-kayit.ps1' } else {
                Test-DbDuplicate -Title 'Test 5: aynı numarayla 2 kayıt, 2 farklı referans' -InvoiceNumber "${prefix}DUP"
            }
        }
        6 {
            $prefix = Get-LatestPrefix 6
            $results['6'] = if (-not $prefix) { Write-NotRun 6 '6-seed.ps1' } else {
                Test-DbSeed -Title 'Test 6: iki çalıştırmada aynı istekler aynı davranışla kayıtlı' -Base $prefix
            }
        }
        7 {
            $prefix = Get-LatestPrefix 7
            $results['7'] = if (-not $prefix) { Write-NotRun 7 '7-sorgu.ps1' } else {
                $invoice = "${prefix}1"
                # Veritabanındaki referans, simülatörün GET cevabıyla karşılaştırılır.
                $get = Get-Invoice $invoice
                $reference = if ($get.Body -match '"erpReference":"([^"]+)"') { $Matches[1] } else { '' }
                Write-Host ''
                Write-Host "GET $BaseUrl/api/v1/invoices/$invoice -> $($get.Status), erpReference=$reference" -ForegroundColor DarkGray
                Test-DbLookup -Title 'Test 7: GET sonucu veritabanıyla aynı' -InvoiceNumber $invoice `
                    -Reference $reference -MissingInvoiceNumber 'YOK-KONTROL'
            }
        }
    }
}

if ($results.Count -gt 1) {
    Write-Title 'ÖZET'
    foreach ($key in $results.Keys) {
        if ($results[$key]) { Write-Host "  Test $key : GEÇTİ" -ForegroundColor Green }
        else                { Write-Host "  Test $key : KALDI" -ForegroundColor Red }
    }
}
