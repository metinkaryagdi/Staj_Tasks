# Kontrol listesi 4: ham SQL kullanılan her yer ve parametreli olduğu. Kodda ham SQL çağrıları aranır (FromSql, SqlQuery,
# ExecuteSql, NpgsqlCommand), her biri için 2-log-arama.ps1 -AyrintiliLog koşusunun EF logunda o komut bulunur: komut
# metninde değerlerin yerinde parametre adı (@p0, @key ...) olduğu ve gerçek değerin (fatura numarası, event_id) komut
# metnine yazılmadığı gösterilir. Logda görünmeyen (o koşuda çalışmayan ya da EF dışı) komutlar koddan gösterilir.
#   .\manual-tests\gun20\3-ham-sql.ps1
. "$PSScriptRoot\_common.ps1"

New-Report 'b-ham-sql'
Write-Title 'Kontrol listesi 4) Ham SQL kullanılan yerler parametreli'
$logFile = Join-Path $OutputDir 'b-log-arama-ayrintili-loglar.txt'
if (-not (Test-Path $logFile)) { throw "Önce .\manual-tests\gun20\2-log-arama.ps1 -AyrintiliLog koşulmalı ($logFile yok)." }
$log = @(Get-Content $logFile -Encoding UTF8 | Where-Object { $_ -match 'Executed DbCommand|Failed executing DbCommand' })

$calls = @(Get-ChildItem (Join-Path $RepoRoot 'invoice-service\src'), (Join-Path $RepoRoot 'erp-simulator\src') -Recurse -Filter *.cs |
    Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' } |
    Select-String -Pattern 'FromSql|SqlQuery|ExecuteSql|new NpgsqlCommand\(|migrationBuilder\.Sql\(')
Write-Line "Koddaki ham SQL çağrıları: $($calls.Count) (bin/obj hariç)"

# Her çağrı için komutun logda tanınacağı parça ve (varsa) logda komut metnine yazılmaması gereken bir değer biçimi.
$known = @(
    @{ File = 'InvoiceStore.cs'; Line = 14; Find = 'SELECT nextval\('; How = 'Parametre yok: dizi adı koddaki sabit (InvoiceDbContext.InvoiceNumberSequence), dışarıdan değer girmez.' }
    @{ File = 'InvoiceStore.cs'; Line = 87; Find = 'FROM invoices WHERE invoice_number = @\w+ FOR UPDATE' }
    @{ File = 'OperatorActionStore.cs'; Line = 12; Find = 'INSERT INTO operator_actions' }
    @{ File = 'OutboxStore.cs'; Line = 16; Find = 'WITH due AS' }
    @{ File = 'OutboxStore.cs'; Line = 84; Find = 'INSERT INTO erp_outbox \(invoice_number, status, attempt_count, next_attempt_at, created_at\)\s+VALUES \(@\w+, @\w+, 0' }
    @{ File = 'PostgresSendPacer.cs'; Line = 17; Find = 'UPDATE erp_send_pace' }
    @{ File = 'ReconciliationStore.cs'; Line = 27; Find = 'UPDATE reconciliation_runs r' }
    @{ File = 'WebhookEventStore.cs'; Line = 17; Find = 'SET LOCAL lock_timeout'; How = 'SET parametre almaz; iki değer de int (ayar dosyasından, servis açılırken doğrulanır), InvariantCulture ile metne çevrilir. İstekten gelen bir değer girmez.' }
    @{ File = 'WebhookEventStore.cs'; Line = 21; Find = 'INSERT INTO erp_webhook_events' }
    @{ File = 'WebhookEventStore.cs'; Line = 44; Find = 'FROM erp_webhook_events\s+WHERE invoice_number = @\w+' }
    @{ File = 'WebhookEventStore.cs'; Line = 53; Find = 'UPDATE erp_webhook_events e' }
    @{ File = 'AdvisoryReconciliationLock.cs'; Line = 30; Find = $null; How = 'EF dışı NpgsqlCommand: metin sabit "SELECT pg_try_advisory_lock(@key)", değer command.Parameters.AddWithValue("key", Key) ile; Key koddaki sabit.' }
    @{ File = 'ErpInvoiceStore.cs'; Line = 13; Find = 'pg_advisory_xact_lock\(hashtextextended\(@\w+' }
)

Write-Line ''
Write-Line 'Yer | logda görüldü mü | komut metni (ilk 150 karakter) | parametreler'
$allParameterized = $true
foreach ($call in $calls) {
    $file = $call.Filename; $line = $call.LineNumber
    $rel = $call.Path.Substring($RepoRoot.Length + 1)
    if ($call.Line -match 'migrationBuilder\.Sql\(') {
        Write-Line "  $rel`:$line | migration | sabit SQL metni, yalnızca migration sırasında; istekten değer girmez"
        continue
    }
    $entry = $known | Where-Object { $_.File -eq $file -and $_.Line -eq $line } | Select-Object -First 1
    if (-not $entry) { Check $false "$rel`:$line | listede yok: yeni bir ham SQL, elle incelenmeli"; continue }
    $hit = if ($entry.Find) { $log | Where-Object { $_ -match $entry.Find } | Select-Object -First 1 }
    if ($hit) {
        $params = if ($hit -match '\[Parameters=\[(.*?)\], CommandType') { $Matches[1] } else { '' }
        $sql = ($hit -replace '^.*?CommandTimeout=''\d+''\]\s*', '')
        # Değer komut metnine yazılmışsa logda FTR-/ERP-/gun20- gibi bir değer tırnak içinde görünür.
        $literal = $sql -match "'(FTR-|ERP-|gun20-|evt-)"
        $ok = (-not $literal) -and ($params -ne '' -or $entry.How)
        Check $ok ("{0}:{1} | logda | {2} | [{3}]" -f $rel, $line, $sql.Substring(0, [Math]::Min(150, $sql.Length)), $params)
        if ($entry.How) { Write-Line "      $($entry.How)" }
        if (-not $ok) { $allParameterized = $false }
    }
    else {
        Write-Line ("  [KOD]   {0}:{1} | bu koşuda logda yok | {2}" -f $rel, $line, $(if ($entry.How) { $entry.How } else { 'FormattableString ($"..."): EF her {değer}i DbParameter olarak gönderir' }))
        Write-Line "      kod: $($call.Line.Trim())"
    }
}

Save-Report
Write-Result $allParameterized 'Ham SQL''lerin hepsi parametreli ya da yalnızca sabit/doğrulanmış sayı içeriyor.'
