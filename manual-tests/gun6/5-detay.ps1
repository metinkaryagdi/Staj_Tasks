# Gün 6 - Madde 5: bir faturanın detayındaki outbox kaydı, haberler ve bulgular veritabanıyla aynı mı. ~1 dk.
#
#   Farklı durumdaki beş fatura seçilir (haberi çok olan, Başarısız, mutabakat bulgusu olan, haberi yok sayılan, bir haberi birden
#   fazla kez gelen; bulunamayanın yerine eldeki en yeni fatura) ve GET /invoices/{no}/details cevabı alan alan veritabanıyla
#   karşılaştırılır: fatura satırı, erp_outbox satırı (deneme sayısı, bir sonraki deneme zamanı, son hata), her haberin event_id,
#   türü, durumu, ignore_reason'ı, kaç kez geldiği ve zamanları, her bulgunun çalışma numarası, türü, işlemi ve ayrıntısı.
#   Kayıt eklemez, hiçbir şeyi değiştirmez.
. "$PSScriptRoot\_common.ps1"

Write-Title 'Madde 5) Fatura detayı: outbox, haberler, bulgular = veritabanı'
$allPassed = $true
function Check([bool]$Passed) { if (-not $Passed) { $script:allPassed = $false } }

Wait-Service

function Get-FirstOrNull([string]$Sql) { $r = @(Get-ServiceRows $Sql); if ($r.Count -gt 0) { $r[0] } else { $null } }

$candidates = [ordered]@{
    'haberi birden çok olan'            = Get-FirstOrNull "SELECT invoice_number FROM erp_webhook_events WHERE status = 'İşlendi' GROUP BY invoice_number HAVING count(*) >= 2 ORDER BY max(received_at) DESC LIMIT 1;"
    'Başarısız (outbox Başarısız)'      = Get-FirstOrNull "SELECT i.invoice_number FROM invoices i JOIN erp_outbox o USING (invoice_number) WHERE i.status = 'Başarısız' ORDER BY i.updated_at DESC LIMIT 1;"
    'Başarısız (outbox kaydı yok)'      = Get-FirstOrNull "SELECT i.invoice_number FROM invoices i LEFT JOIN erp_outbox o USING (invoice_number) WHERE i.status = 'Başarısız' AND o.id IS NULL ORDER BY i.updated_at DESC LIMIT 1;"
    'mutabakat bulgusu olan'            = Get-FirstOrNull "SELECT f.invoice_number FROM reconciliation_findings f JOIN invoices i USING (invoice_number) ORDER BY f.id DESC LIMIT 1;"
    'haberi yok sayılan'                = Get-FirstOrNull "SELECT e.invoice_number FROM erp_webhook_events e JOIN invoices i USING (invoice_number) WHERE e.status = 'Yok Sayıldı' ORDER BY e.received_at DESC LIMIT 1;"
    'bir haberi birden fazla gelen'     = Get-FirstOrNull "SELECT e.invoice_number FROM erp_webhook_events e JOIN invoices i USING (invoice_number) WHERE e.delivery_count > 1 ORDER BY e.received_at DESC LIMIT 1;"
    'en yeni fatura'                    = Get-FirstOrNull "SELECT invoice_number FROM invoices ORDER BY created_at DESC, invoice_number DESC LIMIT 1;"
}

foreach ($kind in $candidates.Keys) {
    $number = $candidates[$kind]
    Write-Host ''
    if (-not $number) { Write-Host "  [$kind] veritabanında böyle fatura yok, atlandı." -ForegroundColor DarkGray; continue }
    Write-Host "  [$kind] $number" -ForegroundColor Yellow

    $detail = (Get-Api "/api/v1/invoices/$number/details").Json
    Show-ServiceQuery "SELECT invoice_number, i.status, o.status AS outbox, o.attempt_count AS outbox_deneme, o.next_attempt_at, i.last_error FROM invoices i LEFT JOIN erp_outbox o USING (invoice_number) WHERE invoice_number = '$number';"
    Show-ServiceQuery "SELECT event_id, event_type, status, ignore_reason, delivery_count FROM erp_webhook_events WHERE invoice_number = '$number' ORDER BY received_at, occurred_at;"
    Show-ServiceQuery "SELECT id, run_id, finding_type, action FROM reconciliation_findings WHERE invoice_number = '$number' ORDER BY id DESC;"

    # Fatura
    $dbInvoice = @(Get-ServiceRows "SELECT status, customer_code, amount, coalesce(erp_reference,''), coalesce(reject_reason,''), coalesce(last_error,''), send_attempt_count, $(Get-SqlUtcSeconds 'updated_at') FROM invoices WHERE invoice_number = '$number';")[0]
    $i = $detail.invoice
    $apiInvoice = @($i.status, $i.customerCode, ([decimal]$i.amount).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture), $(if ($i.erpReference) { $i.erpReference } else { '' }), $(if ($i.rejectReason) { $i.rejectReason } else { '' }),
                    $(if ($i.lastError) { $i.lastError } else { '' }), $i.sendAttemptCount, (ConvertTo-UtcSeconds $i.updatedAt)) -join '|'
    Check (Write-DbVerdict "fatura: $dbInvoice" $apiInvoice ($apiInvoice -eq $dbInvoice))

    # Outbox
    $dbOutbox = Get-FirstOrNull "SELECT status, attempt_count, $(Get-SqlUtcSeconds 'next_attempt_at'), coalesce(last_error,''), $(Get-SqlUtcSeconds 'created_at'), coalesce($(Get-SqlUtcSeconds 'processed_at'),'') FROM erp_outbox WHERE invoice_number = '$number';"
    $o = $detail.outbox
    $apiOutbox = if ($o) { @($o.status, $o.attemptCount, (ConvertTo-UtcSeconds $o.nextAttemptAt), $(if ($o.lastError) { $o.lastError } else { '' }), (ConvertTo-UtcSeconds $o.createdAt), (ConvertTo-UtcSeconds $o.processedAt)) -join '|' } else { $null }
    Check (Write-DbVerdict "outbox: $(if ($dbOutbox) { $dbOutbox } else { 'kayıt yok' })" $(if ($apiOutbox) { $apiOutbox } else { 'kayıt yok' }) ($apiOutbox -eq $dbOutbox))

    # Haberler
    $dbEvents = @(Get-ServiceRows "SELECT event_id, event_type, status, coalesce(ignore_reason,''), delivery_count, $(Get-SqlUtcSeconds 'occurred_at'), $(Get-SqlUtcSeconds 'received_at'), coalesce($(Get-SqlUtcSeconds 'processed_at'),'') FROM erp_webhook_events WHERE invoice_number = '$number' ORDER BY received_at, occurred_at;")
    $apiEvents = @($detail.events | ForEach-Object {
        @($_.eventId, $_.eventType, $_.status, $(if ($_.ignoreReason) { $_.ignoreReason } else { '' }), $_.deliveryCount,
          (ConvertTo-UtcSeconds $_.occurredAt), (ConvertTo-UtcSeconds $_.receivedAt), (ConvertTo-UtcSeconds $_.processedAt)) -join '|' })
    Check (Write-DbVerdict "$($dbEvents.Count) haber, aynı sırada, her alan aynı" "$($apiEvents.Count) haber" (($apiEvents -join ';') -eq ($dbEvents -join ';')))

    # Bulgular
    $dbFindings = @(Get-ServiceRows "SELECT id, run_id, finding_type, action, details FROM reconciliation_findings WHERE invoice_number = '$number' ORDER BY id DESC;")
    $apiFindings = @($detail.findings | ForEach-Object { @($_.id, $_.runId, $_.findingType, $_.action, $_.details) -join '|' })
    Check (Write-DbVerdict "$($dbFindings.Count) bulgu, en yeni üstte, her alan aynı" "$($apiFindings.Count) bulgu" (($apiFindings -join ';') -eq ($dbFindings -join ';')))
}

Write-Result $allPassed 'detaydaki fatura, outbox, haberler ve bulgular veritabanıyla aynı'
