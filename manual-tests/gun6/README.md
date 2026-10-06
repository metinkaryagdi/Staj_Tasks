# Gün 6 — Operasyon Ekranı: kontrol listesi

Önce `docker compose up -d --build` (ekran http://localhost:5100, Fatura Servisi http://localhost:5090).
Script'ler repo kök klasöründen çalıştırılır. Hepsi sonunda `SONUÇ: GEÇTİ` ya da `KALDI` yazar; her kontrolde veritabanı
çıktısı ve beklenen / gelen değer görünür.

| # | Madde | Nasıl |
|---|---|---|
| 1 | 25 saat eski, kararı gelmemiş fatura mutabakatla düzeltiliyor | `.\manual-tests\gun5\ek-eski-takili-fatura.ps1`; sonra ekranda Mutabakat → çalışma → Düzeltilen bulgular |
| 2 | Düzeltmesi hata veren fatura bulgu olarak kaydediliyor, nedeni görünüyor | `.\manual-tests\gun5\ek-duzeltme-hatasi.ps1` (hatayı veritabanında bir trigger oluşturur); ekranda Raporlanan bulgular ve fatura detayı |
| 3 | 1000 fatura, Özet sayıları = veritabanı | `.\manual-tests\gun6\3-ozet-1000.ps1`; sonra Özet sayfasındaki sayıları script çıktısıyla karşılaştırın |
| 4 | Liste: durum filtresi, arama, sayfalama | `.\manual-tests\gun6\4-liste-1000.ps1` |
| 5 | Detay: outbox, haberler, bulgular = veritabanı | `.\manual-tests\gun6\5-detay.ps1` |
| 6 | Başarısız fatura ekrandan yeniden gönderiliyor: Bekliyor → Gönderildi | ekranda, aşağıya bakın |
| 7 | İki pencereden aynı faturayı aynı anda yeniden gönder | ekranda, aşağıya bakın |
| 8 | 20 Başarısız fatura toplu yeniden gönderiliyor, sonuç özeti | `.\manual-tests\gun6\8-toplu-yeniden-gonder.ps1`; ekranda aynısı: listede Başarısız süzgeci → "sayfadaki hepsini seç" → Seçilenleri Yeniden Gönder |
| 9 | Mutabakat sürerken tekrar basış | ekranda, aşağıya bakın |
| 10 | Servis durunca ekran çökmüyor, açılınca toparlanıyor | ekranda, aşağıya bakın |

Script'li maddeleri art arda çalıştırmak için: `.\manual-tests\gun6\kontrol-listesi.ps1` (1-5 ve 8).
Ek: `adim1-okuma.ps1` (Fatura Servisi okuma uç noktaları ve CORS) ve `adim2-mudahale.ps1` (toplu resend, 409 kodları) uç nokta testleridir.

## Ekrandan elle yapılan maddeler

**6) Bekliyor → Gönderildi.** Bekliyor durumu normalde bir saniyeden kısa sürer; görebilmek için simülatör geçici olarak meşgul yapılır:

```powershell
$env:Simulator__Rates__Success='0'; $env:Simulator__Rates__Busy='100'; $env:Simulator__Rates__ServerError='0'; $env:Simulator__Rates__SaveThenError='0'; $env:Simulator__Rates__LateResponse='0'
docker compose up -d --force-recreate erp-simulator
```

Faturalar listesinde Başarısız süzgeciyle bir faturanın detayına girin, **Yeniden Gönder**'e basın: durum Bekliyor olur, outbox kaydında deneme sayısı artar.
Sonra simülatörü varsayılan ayarlarına döndürün (`Remove-Item Env:Simulator__Rates__*; docker compose up -d --force-recreate erp-simulator`);
sayfa 10 saniyede bir yenilenir, fatura Gönderildi olur.

**7) İki pencere.** Aynı Başarısız faturanın detayını iki tarayıcı penceresinde açın; birinde **Yeniden Gönder**'e basın, hemen ardından
diğerinde basın. Birincisi "kuyruğa alındı" der, ikincisi "Bu fatura artık Başarısız durumda değil, şu an Bekliyor ... Başka biri
faturayı az önce yeniden göndermiş olabilir" mesajını görür.

**9) Mutabakat.** Mutabakat sayfasında **Mutabakatı Şimdi Çalıştır**'a basın, çalışma sürerken (Çalışıyor) tekrar basın:
"Mutabakat zaten çalışıyor. Bitmesini bekleyin ..." mesajı görünür. (24 binden fazla fatura varsa bir çalışma ~30 sn sürer.)

**10) Servis durunca.** `docker compose stop invoice-service` → ekran çökmez, her sayfada "Fatura Servisi'ne ulaşılamıyor ..." mesajı görünür
(veri daha önce geldiyse son bilinen veri ve uyarı birlikte). `docker compose start invoice-service` → birkaç saniye içinde mesaj
kendiliğinden kalkar, veri yenilenir; sayfayı elle yenilemek gerekmez.
