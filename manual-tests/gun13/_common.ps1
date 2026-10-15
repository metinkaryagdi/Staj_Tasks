# Gün 13 script'lerinin ortak yardımcıları. Gün 12'nin _common.ps1'ini de yükler (Gün 1-12 yardımcıları dahil).
# Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun12\_common.ps1"

# Kontrol listesi boş veritabanıyla başlar: compose bu güne özel volume'lerle açılır (staj-tasks_*-db-data-gun13); eski
# volume'ler silinmez, dokunulmaz.
Use-Gun10Volumes 'gun13'

# Collector'ın karar için beklediği süre (monitoring/otel-collector/config.yaml, tail_sampling.decision_wait). Bir trace'in
# saklanıp saklanmadığı ancak bu süre geçince belli olur; sayımlar bundan sonra yapılır.
$DecisionWaitSeconds = 1800

function ConvertTo-JaegerTime([DateTimeOffset]$Time) { $Time.ToUnixTimeMilliseconds() * 1000 }

# Jaeger'da invoice.number etiketi bu fatura olan trace'lerin kimlikleri ($From-$To arasında başlayan).
function Get-InvoiceTraceIds([string]$InvoiceNumber, [DateTimeOffset]$From, [DateTimeOffset]$To) {
    $tags = [Uri]::EscapeDataString((@{ 'invoice.number' = $InvoiceNumber } | ConvertTo-Json -Compress))
    $url = "$JaegerUrl/api/traces?service=invoice-service&tags=$tags&start=$(ConvertTo-JaegerTime $From)&end=$(ConvertTo-JaegerTime $To)&limit=100"
    @((Get-JaegerJson $url).data | ForEach-Object { $_.traceID } | Sort-Object -Unique)
}

# Bir trace'in span'leri: Name, Service, Tags (sözlük).
function Get-TraceSpans([string]$TraceId) {
    $raw = @((Get-JaegerJson "$JaegerUrl/api/traces/$TraceId").data)[0]
    foreach ($s in $raw.spans) {
        $t = @{}; foreach ($x in $s.tags) { $t[$x.key] = $x.value }
        [pscustomobject]@{ Name = $s.operationName; Service = $raw.processes.($s.processID).serviceName; Tags = $t; Start = $s.startTime }
    }
}

# Bir servisin $From-$To arasında başlayan bütün trace'leri (Jaeger arama sınırı $Limit).
function Get-ServiceTraces([string]$Service, [DateTimeOffset]$From, [DateTimeOffset]$To, [int]$Limit = 10000) {
    @((Get-JaegerJson "$JaegerUrl/api/traces?service=$Service&start=$(ConvertTo-JaegerTime $From)&end=$(ConvertTo-JaegerTime $To)&limit=$Limit").data)
}
