# Gün 15 script'lerinin ortak yardımcıları. Gün 14'ün _common.ps1'ini de yükler (Gün 1-14 yardımcıları dahil).
# Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun14\_common.ps1"

# Kontrol listesi boş veritabanıyla başlar: compose bu güne özel volume'lerle açılır (staj-tasks_*-db-data-gun15-<Name>);
# eski volume'ler silinmez, dokunulmaz.
Use-Gun10Volumes 'gun15'

# Collector'ın 15 sn'de bir yazılan metrik dosyasını (# T <unix saniye> satırıyla başlayan ölçümler) okur: her ölçüm
# için At ve Lines (otelcol_ satırları).
function Read-CollectorSnapshots([string]$File) {
    foreach ($part in ((Get-Content $File -Raw -Encoding UTF8) -split '(?m)^# T ' | Where-Object { $_.Trim() })) {
        $lines = @($part -split "`r?`n")
        [pscustomobject]@{ At = [DateTimeOffset]::FromUnixTimeSeconds([long]$lines[0].Trim()); Lines = @($lines | Select-Object -Skip 1) }
    }
}

# Get-JaegerJson, geçici bir hatada (zaman aşımı) üç kez daha denenerek: saatler süren sayım tek bir hatada durmasın.
function Get-JaegerJsonRetry([string]$Url) {
    for ($try = 1; ; $try++) {
        try { return Get-JaegerJson $Url }
        catch {
            if ($try -ge 4) { throw }
            Write-Host "  Jaeger hatası ($try. deneme): $($_.Exception.Message); 5 sn sonra tekrar" -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    }
}

# Bir faturanın izlerini türüne göre ayırır. Jaeger'da invoice.number ile bulunan trace'ler:
#   fatura izi: worker'ın kuyruktan ilk alışında başlayan iz (outbox.queue_wait ya da outbox.attempt span'i var),
#   oluşturma izi: oluşturma isteğinin kendi izi (fatura servisinde POST /api/v1/invoices span'i var, deneme yok).
function Split-InvoiceTraces($Traces) {
    $invoice = @(); $creation = @()
    foreach ($t in @($Traces)) {
        $names = @($t.spans | ForEach-Object { $_.operationName })
        if ($names -contains 'outbox.queue_wait' -or $names -contains 'outbox.attempt') { $invoice += $t }
        elseif (@($t.spans | Where-Object { $_.operationName -like 'POST /api/v1/invoices*' -and $t.processes.($_.processID).serviceName -eq 'invoice-service' }).Count) { $creation += $t }
    }
    [pscustomobject]@{ Invoice = $invoice; Creation = $creation }
}

# Jaeger'ın döndürdüğü bir trace'i Show-Trace'in (Gün 12) beklediği biçime çevirir: TraceId, Spans.
function ConvertTo-Trace($Raw) {
    $start = ($Raw.spans | Measure-Object -Property startTime -Minimum).Minimum
    $spans = foreach ($s in $Raw.spans) {
        $t = @{}; foreach ($x in $s.tags) { $t[$x.key] = $x.value }
        $parent = @($s.references | Where-Object { $_.refType -eq 'CHILD_OF' -and $_.traceID -eq $Raw.traceID } | Select-Object -First 1).spanID
        [pscustomobject]@{
            Name = $s.operationName; Service = $Raw.processes.($s.processID).serviceName; Id = $s.spanID; ParentId = $parent
            Start = [math]::Round(($s.startTime - $start) / 1000); Ms = [math]::Round($s.duration / 1000); Tags = $t
            Events = @($s.logs | ForEach-Object { $e = @{}; foreach ($f in $_.fields) { $e[$f.key] = $f.value }; $e } | Where-Object { $_.event -like 'erp event*' })
            Links = @($s.references | Where-Object { $_.traceID -ne $Raw.traceID })
        }
    }
    [pscustomobject]@{ TraceId = $Raw.traceID; Spans = @($spans) }
}

# Bir sayfanın ekran görüntüsü, başsız Edge ile (Jaeger arayüzü sayfayı tarayıcıda çizer; çizim için süre tanınır).
function Save-Screenshot([string]$Url, [string]$File, [int]$Width = 1800, [int]$Height = 1400) {
    $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $edge) { throw 'Edge bulunamadı.' }
    $edgeProfile = Join-Path $env:TEMP "gun15-edge-$([guid]::NewGuid().ToString('N'))"
    $p = Start-Process $edge -ArgumentList @('--headless=new', '--disable-gpu', '--hide-scrollbars', "--user-data-dir=$edgeProfile",
        "--window-size=$Width,$Height", '--virtual-time-budget=20000', "--screenshot=$File", "`"$Url`"") -PassThru -Wait -WindowStyle Hidden
    Remove-Item $edgeProfile -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $File)) { throw "Ekran görüntüsü alınamadı: $Url" }
}
