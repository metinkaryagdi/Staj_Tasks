# Gün 11 — kontrol listesi

Script'ler repo kökünden PowerShell ile çalıştırılır. Compose kontrol listesine özel, boş veritabanı volume'leriyle açılır
(eski volume'ler silinmez); yük testi de aynı volume'lerle çalıştırılır:

```powershell
$env:GUN10_VOL = 'gun11'; $env:COMPOSE_FILE = 'docker-compose.yml;manual-tests/gun10/compose.volumes.yml'
docker compose up -d --build
```

Alarm script'leri koşulu oluşturur, alarmın alıcının logunda (`docker compose logs alert-receiver`) `status=firing` ile
görünmesini, sonra koşulu kaldırıp `status=resolved` ile görünmesini bekler. Çıktılar `manual-tests/output/` altına yazılır.

| Madde | Script | Süre (yaklaşık) |
|---|---|---|
| 1. Pano elle bir şey yapmadan açılıyor (ekran görüntüsü tarayıcıdan) | `1-pano-hazir.ps1` | 1 dk |
| 2. Yük sırasında pano = simülatörün saniye sayımları ve servisin veritabanı okuması (ekran görüntüsü yük sürerken) | ayrı pencerede `docker compose run --rm k6`, sonra `2-yuk-pano.ps1` | 5 dk |
| 3. Alarm 1, kuyruk (2. maddenin yük testiyle oluşur) | yük testi başlayınca `3-alarm-kuyruk.ps1` | 45 dk |
| 3. Alarm 2, takılı fatura | `4-alarm-takili.ps1` | 15 dk |
| 3. Alarm 3, ERP'ye ulaşılamıyor (simülatör durdurulur; `-Timeout` ile her isteğe geç cevap verir) | `5-alarm-erp.ps1`, `5-alarm-erp.ps1 -Timeout` | 5-10 dk |
| 3. Alarm 4, başarılı mutabakat yok (mutabakat aralığı 1 dk, ERP kapalı, çalışmalar Başarısız) | `6-alarm-mutabakat.ps1` | 2 sa 5 dk |
| 3. Alarm 5, 401 (simülatörün sahte ve tekrar oynatılan haberleri kapatılır) | `7-alarm-401.ps1` | 7-12 dk |
| 4. Yük ve hata yokken 15 dakika alarm yok | `8-alarmsiz-15dk.ps1` | 15-25 dk |
| 5. Prometheus 5 sn'de bir toplar, veritabanına en az 15 sn arayla okuma gider | `9-veritabani-okuma.ps1` | 3 dk |
| 6. Metriklerin adları ve neyi ölçtükleri | `10-metrik-listesi.ps1` | 2 dk |

2. maddede ilk örnek simülatördeki ilk POST'tan 60 saniye sonra alınır (panodaki değer son 1 dakikanın ortalamasıdır; o dakika
tamamen yük içinde olmalıdır), sonra yaklaşık her 15 saniyede bir. Gönderim hızı: panodaki değer (son 1 dakikanın saniye ortalaması), simülatör logunda
aynı 60 saniyenin saniye başına POST sayımlarının ortalamasıyla karşılaştırılır. Kuyruk ve en eski bekleme: Prometheus'taki değer,
servisin o toplamadan önceki son veritabanı okumasıyla (özet API'sinin aynı sorgusu) birebir karşılaştırılır. Simülatörün logu ve
saniye tablosu (`gun11-yuk-simulator.log`, `gun11-yuk-saniye.csv`) kaydedilir.

Kontrol listesi testlerinin oluşturmadığı iki sayaç ayrıca sınanır:

| Sayaç | Nasıl | Süre |
|---|---|---|
| `erp_webhooks_received_total{result="503"}` | `..\gun4\ek-cevap-suresi.ps1` (aynı ortam değişkenleriyle) gerçek 503 üretir; sayacın artışı servis logundaki `http=503` satırlarıyla karşılaştırılır | 2 dk |
| `erp_simulator_rate_limited_total` | `11-hiz-siniri-429.ps1`: simülatöre aynı anda 30 istek | 1 dk |

Yük testi sırasında alarm 1'den başka alarmlar da tetiklenebilir: simülatörün varsayılan ayarlarında karar haberlerinin %5'i hiç
gönderilmez (takılı fatura birikir, alarm 2) ve haberlerin %5'i yanlış anahtarla imzalanır (401, alarm 5). Her alarmın kendi
koşulu ayrı script'tedir. 4. madde en sona bırakılır: önceki testlerin alarmlarının çözülmesini bekler.
