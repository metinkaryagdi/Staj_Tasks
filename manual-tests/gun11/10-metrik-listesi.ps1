# 6. madde: eklenen metriklerin adları ve neyi ölçtükleri. İki uygulamanın /metrics çıktısından okunur (Prometheus'taki
# adlarıyla); etiketler de yazılır. Histogramlar ilk ölçümden önce /metrics'te görünmez: önce bir fatura gönderilir ve bir
# mutabakat çalıştırılır.
#   .\manual-tests\gun11\10-metrik-listesi.ps1
. "$PSScriptRoot\_common.ps1"

Write-Title 'Eklenen metrikler'

Write-Step 'Bir fatura gönderiliyor ve bir mutabakat çalıştırılıyor (histogramların ilk ölçümü)'
$number = (New-ServiceInvoice).InvoiceNumber
Wait-InvoicesIn @($number) @('Gönderildi', 'İşleme Alındı', 'Onaylandı', 'Reddedildi', 'Başarısız') 300 'gönderildi' | Out-Null
Show-Run (Invoke-Reconciliation).run.id
Start-Sleep -Seconds 6

function Get-MetricList([string]$App, [string]$Url) {
    $text = (Invoke-WebRequest "$Url/metrics" -UseBasicParsing -TimeoutSec 10).Content
    $lines = $text -split "`n"
    $help = @{}; $type = @{}
    foreach ($l in $lines) {
        if ($l -match '^# HELP (\S+) (.*)$') { $help[$Matches[1]] = $Matches[2] }
        elseif ($l -match '^# TYPE (\S+) (\S+)') { $type[$Matches[1]] = $Matches[2] }
    }
    foreach ($name in ($type.Keys | Where-Object { $_ -ne 'target_info' } | Sort-Object)) {
        $samples = @($lines | Where-Object { $_ -match "^$name(_bucket|_sum|_count|_total)?\{" })
        $labels = @($samples | ForEach-Object { [regex]::Matches($_, '(\w+)="') | ForEach-Object { $_.Groups[1].Value } } |
            Where-Object { $_ -notin 'otel_scope_name', 'le' } | Sort-Object -Unique)
        [pscustomobject]@{ Uygulama = $App; Metrik = $name; Tür = $type[$name]; Etiketler = $labels -join ', '; Açıklama = $help[$name] }
    }
}

$list = @(Get-MetricList 'Fatura Servisi' $ServiceUrl) + @(Get-MetricList 'ERP Simülatörü' $SimulatorUrl)
$list | Format-Table -AutoSize -Wrap | Out-String -Width 250 | Write-Host
$list | Format-Table -AutoSize -Wrap | Out-String -Width 250 | Set-Content (Join-Path $OutputDir 'gun11-metrikler.txt') -Encoding UTF8
Write-Host "  $($list.Count) metrik; liste: manual-tests\output\gun11-metrikler.txt" -ForegroundColor DarkGray
