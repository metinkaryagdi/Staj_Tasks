# Gün 12 script'lerinin ortak yardımcıları. Gün 11'in _common.ps1'ini de yükler (Gün 1-11 yardımcıları dahil).
# Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun11\_common.ps1"

# Kontrol listesi boş veritabanıyla başlar: compose bu güne özel volume'lerle açılır (staj-tasks_*-db-data-gun12); eski
# volume'ler silinmez, dokunulmaz.
Use-Gun10Volumes 'gun12'

$JaegerUrl = 'http://localhost:16686'

# Jaeger'ın JSON cevabı; karakter kümesi yazmadığı için UTF-8 olarak çözülür (PowerShell 5.1 aksi halde Latin-1 sanar).
function Get-JaegerJson([string]$Url) {
    $r = Invoke-WebRequest $Url -UseBasicParsing -TimeoutSec 10
    [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
}

# Panonun (monitoring/grafana/dashboards/fatura-servisi.json) her sorgusunu Prometheus'ta çalıştırır; satırları döner.
# "> 0" süzgeçli bulgu sorgusu bulgu yoksa boş döner, hatasız çalışması yeterli sayılır.
function Test-DashboardQueries {
    $dashboard = Get-Content (Join-Path $RepoRoot 'monitoring\grafana\dashboards\fatura-servisi.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($panel in $dashboard.panels) {
        foreach ($target in @($panel.targets)) {
            if (-not $target.expr) { continue }
            $rows = @(Get-Prometheus $target.expr)
            $optional = $target.expr -match '> 0$'
            [pscustomobject]@{ Panel = $panel.title; Seri = $rows.Count; Tamam = ($rows.Count -gt 0 -or $optional) }
        }
    }
}

# Jaeger'dan faturanın izi: invoice.number etiketiyle aranır, tek trace beklenir. Span'ler en fazla 5 sn sonra gönderildiği
# için span sayısı iki okumada aynı kalana kadar beklenir. Dönen nesne: TraceId, Spans (her biri Name, Service, Id,
# ParentId, Start, Ms, Tags, Events, Links).
function Get-InvoiceTrace([string]$InvoiceNumber, [int]$TimeoutSeconds = 60) {
    $tags = [Uri]::EscapeDataString((@{ 'invoice.number' = $InvoiceNumber } | ConvertTo-Json -Compress))
    $url = "$JaegerUrl/api/traces?service=invoice-service&tags=$tags&lookback=6h&limit=20"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $previous = -1
    while ($true) {
        $traces = @((Get-JaegerJson $url).data)
        $ids = @($traces | ForEach-Object { $_.traceID } | Sort-Object -Unique)
        if ($ids.Count -gt 1) { throw "$InvoiceNumber için birden fazla trace var: $($ids -join ', ')" }
        if ($ids.Count -eq 1) {
            $raw = @((Get-JaegerJson "$JaegerUrl/api/traces/$($ids[0])").data)[0]
            if ($raw.spans.Count -eq $previous) { break }
            $previous = $raw.spans.Count
        }
        if ((Get-Date) -gt $deadline) { throw "$TimeoutSeconds sn içinde Jaeger'da $InvoiceNumber izi tamamlanmadı." }
        Start-Sleep -Seconds 6
    }

    $start = ($raw.spans | Measure-Object -Property startTime -Minimum).Minimum
    $spans = foreach ($s in $raw.spans) {
        $t = @{}; foreach ($x in $s.tags) { $t[$x.key] = $x.value }
        $parent = @($s.references | Where-Object { $_.refType -eq 'CHILD_OF' -and $_.traceID -eq $raw.traceID } | Select-Object -First 1).spanID
        [pscustomobject]@{
            Name = $s.operationName; Service = $raw.processes.($s.processID).serviceName; Id = $s.spanID; ParentId = $parent
            Start = [math]::Round(($s.startTime - $start) / 1000); Ms = [math]::Round($s.duration / 1000); Tags = $t
            Events = @($s.logs | ForEach-Object { $e = @{}; foreach ($f in $_.fields) { $e[$f.key] = $f.value }; $e } | Where-Object { $_.event -like 'erp event*' })
            Links = @($s.references | Where-Object { $_.traceID -ne $raw.traceID })
        }
    }
    [pscustomobject]@{ TraceId = $raw.traceID; Spans = @($spans) }
}

# İzi ağaç olarak yazar (veritabanı span'leri hariç, sayıları parantezde): başlangıç ms, süre ms, span, servis, önemli
# etiketler, olaylar ve link'ler. Satırlar $Out dosyasına da yazılır.
function Show-Trace($Trace, [string]$Out) {
    $keep = 'invoice.number', 'http.response.status_code', 'simulator.outcome', 'outbox.attempt', 'outbox.outcome',
        'outbox.wait_seconds', 'outbox.check', 'outbox.queue_wait_seconds', 'erp.http_status', 'erp.retry_after',
        'erp.pace_wait_seconds', 'erp_event.type', 'erp_event.status', 'webhook.attempt', 'webhook.outcome', 'webhook.kind'
    $children = @{}
    foreach ($s in $Trace.Spans) { $key = if ($s.ParentId) { $s.ParentId } else { '' }; if (-not $children[$key]) { $children[$key] = @() }; $children[$key] += $s }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("trace $($Trace.TraceId)  ($($Trace.Spans.Count) span)  $JaegerUrl/trace/$($Trace.TraceId)")
    function Add-Span($s, [int]$Depth) {
        $kids = @($children[$s.Id] | Sort-Object Start)
        $db = @($kids | Where-Object { $_.Name -eq 'postgresql' }).Count
        $tags = ($keep | Where-Object { $null -ne $s.Tags[$_] -and "$($s.Tags[$_])" -ne '' } | ForEach-Object { "$_=$($s.Tags[$_])" }) -join ' '
        $extra = @()
        if ($db) { $extra += "db:$db" }
        if ($s.Links.Count) { $extra += "link:$($s.Links.Count)" }
        $lines.Add(('{0}{1,7} +{2,-6} {3} [{4}] {5}{6}' -f ('  ' * $Depth), $s.Start, $s.Ms, $s.Name, $s.Service, $tags,
            $(if ($extra) { " ($($extra -join ', '))" } else { '' })))
        foreach ($e in $s.Events) {
            $lines.Add(('{0}        * {1} id={2} status={3} invoice={4}' -f ('  ' * $Depth), $e.event, $e.'erp_event.id', $e.'erp_event.status', $e.'invoice.status'))
        }
        foreach ($k in $kids | Where-Object { $_.Name -ne 'postgresql' }) { Add-Span $k ($Depth + 1) }
    }
    foreach ($root in @($children[''] | Sort-Object Start)) { Add-Span $root 0 }
    $lines | ForEach-Object { Write-Host "  $_" }
    if ($Out) { $lines | Set-Content (Join-Path $OutputDir $Out) -Encoding UTF8 }
}

# Bir faturanın iki servisteki bütün log satırları (zamana göre sıralı).
function Get-AllLogLines {
    Push-Location $RepoRoot
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $service = @(& docker compose logs invoice-service --no-log-prefix 2>$null | ForEach-Object { "invoice-service | $_" })
        $simulator = @(& docker compose logs erp-simulator --no-log-prefix 2>$null | ForEach-Object { "erp-simulator   | $_" })
    }
    finally { $ErrorActionPreference = $previous; Pop-Location }
    @($service + $simulator | Sort-Object { $_.Substring(18) })
}
