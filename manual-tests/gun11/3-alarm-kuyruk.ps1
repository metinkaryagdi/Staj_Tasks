# Alarm 1 (KuyruktaUzunBekleyenFatura): kuyruktaki en eski faturanın bekleme süresi 5 dakika boyunca 15 dakikanın üzerinde.
# Koşul yükle oluşur: 2. maddenin yük testi (saniyede 50 fatura, 5 dakika) gönderilebilenden fazla fatura getirir, kuyruk
# birikir ve en eski bekleme yaklaşık 15. dakikada 15 dakikayı geçer. Hata üreterek (ERP kapalı ya da meşgul) oluşturulamaz:
# fatura 10 denemeden sonra Başarısız olup kuyruktan çıkar. Koşul kuyruk boşalırken kendiliğinden kalkar.
# Yük testi başlatıldıktan hemen sonra (ayrı pencerede docker compose run --rm k6):
#   .\manual-tests\gun11\3-alarm-kuyruk.ps1
. "$PSScriptRoot\_common.ps1"

Write-Title 'Alarm 1: kuyrukta 15 dakikadan uzun bekleyen fatura (yükle)'
Show-AlertRule 'KuyruktaUzunBekleyenFatura'
$since = Get-UtcStamp
$queued = Get-PrometheusValue 'max(outbox_queued)'
if (-not $queued) { Write-Host '  Kuyruk boş: yük testi başlamamış olabilir.' -ForegroundColor Yellow }

$passed = Test-AlertCycle 'KuyruktaUzunBekleyenFatura' $since -FireTimeoutSeconds 2400 -ResolveTimeoutSeconds 2700 -Resolve {
    Write-Host '  Koşul için bir şey yapılmaz: kuyruk boşalırken en eski bekleme 15 dakikanın altına iner.' -ForegroundColor DarkGray
}
Write-Host ("  Şu an kuyrukta {0}, en eski bekleme {1} sn (Prometheus)" -f (Get-PrometheusValue 'max(outbox_queued)'), (Get-PrometheusValue 'max(outbox_oldest_wait_seconds)')) -ForegroundColor DarkGray
Write-Result $passed 'Alarm tetiklendi ve çözüldü bildirimi geldi (alıcının logu)'
