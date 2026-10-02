# Staj_Tasks

Fatura entegrasyonu üzerine staj projesi: Invoice Service ve ona hata üreterek cevap veren, sonra faturanın sonucunu
imzalı webhook'larla bildiren ERP Simulator.

| Uygulama | Klasör | Ne yapar |
|---|---|---|
| ERP Simulator | `erp-simulator/` | Faturaları kabul eden ERP'yi taklit eder; her isteğe seed'li rastgele bir hata davranışı uygular; kaydettiği faturalar için Invoice Service'e imzalı webhook gönderir (bilerek sorunlu) |
| Invoice Service | `invoice-service/` | Faturayı ve Outbox kaydını birlikte kaydeder; arka planda ERP'ye gönderir; ERP'den gelen webhook event'lerini doğrulayıp faturaya işler |

Her günün teslim edilen hali bir git tag'idir; README yalnızca uygulamaları ve **bugünün** işini anlatır.
Önceki günlerin anlatımı ve sonuçları kendi tag'inde durur (bkz. [Günler](#günler)).

## Kurulum

```bash
docker compose up -d --build
```

| Servis | Adres |
|---|---|
| ERP Simulator | http://localhost:5080 (Swagger: http://localhost:5080/swagger) |
| ERP veritabanı | `localhost:5433` — db `erp_simulator`, kullanıcı `erp`, şifre `erp` |
| Invoice Service | http://localhost:5090 (Swagger: http://localhost:5090/swagger) |
| Fatura veritabanı | `localhost:5434` — db `invoice_service`, kullanıcı `invoice`, şifre `invoice` |

İki veritabanı ayrı container'larda, ayrı kullanıcı/şifreyle çalışır. Her uygulamanın yalnızca kendi veritabanının
bağlantı bilgisi ve şifresi vardır; iki uygulama birbirine yalnızca `apps` ağı üzerinden HTTP ile ulaşır.
Veritabanları ayrıca ayrı docker ağlarındadır, bu yüzden karşı uygulama veritabanının adını çözemez. Ancak ayrı ağlar
IP ile erişimi her ortamda engellemez (Docker Desktop'ta engellemiyor); ayrılığı sağlayan, bağlantı bilgileridir.

Her iki uygulamada da şema EF Core migration ile açılışta otomatik oluşur. Docker içinde her uygulama
`appsettings.json`'ın üzerine `appsettings.Docker.json`'ı okur (`ASPNETCORE_ENVIRONMENT=Docker`): veritabanı bağlantısı
ve karşı uygulamanın adresi oradadır.

---

## ERP Simulator

.NET 10, ASP.NET Core Minimal API, kendi PostgreSQL veritabanı (`erp-db`).

### Endpoint'ler

| Endpoint | Davranış |
|---|---|
| `POST /api/v1/invoices` | Body: `invoiceNumber`, `customerCode`, `amount`, `currency`, `invoiceDate`. Seçilen davranışa göre cevap verir (aşağıda). Eksik/geçersiz alan `400`; tutarda virgülden sonra en fazla iki basamak (`1.234` ve `1.230` → `400`; `1.23`, `1.20` kabul). |
| `GET /api/v1/invoices/{invoiceNumber}` | `200` + `registered`, `erpReference` (ilk kayıt), `recordCount`, `records[]`. Kayıt yoksa `404`. Hata üretmez. |

```json
POST /api/v1/invoices
{ "invoiceNumber": "INV-2026-0001", "customerCode": "C-001", "amount": 1250.50, "currency": "TRY", "invoiceDate": "2026-09-29" }

202 Accepted
{ "erpReference": "ERP-00000001", "invoiceNumber": "INV-2026-0001", "receivedAt": "2026-09-29T07:00:00+00:00" }
```

### Davranışlar

Geçerli POST için aşağıdaki davranışlardan biri seed'li rastgele seçimle seçilir. Idempotency açıkken mevcut fatura
bulunursa yeni davranış seçilmez. Oranlar gerçek yüzdedir:

| Davranış | Varsayılan oran | Cevap | Fatura kaydedilir mi |
|---|---|---|---|
| `Success` | %60 | `202` + ERP referansı | Evet |
| `Busy` | %15 | `429` + `Retry-After` (5–30 sn) | Hayır |
| `ServerError` | %10 | `500` | Hayır |
| `SaveThenError` | %5 | `500` | Evet |
| `LateResponse` | %10 | 30 sn bekleyip `202` | Evet (önce kayıt tamamlanır, sonra cevap geciktirilir) |

- **Retry-After** iki biçimde gönderilebilir (RFC 9110): saniye `Retry-After: 17` (varsayılan) veya HTTP-date
  `Retry-After: Tue, 29 Sep 2026 07:00:17 GMT`; `RetryAfterFormat` ayarıyla seçilir.
- **Çift kayıt varsayılan olarak engellenmez:** kaydeden bir davranış seçilirse aynı fatura numarası tekrar kaydedilebilir.
  `IdempotentInvoices` ayarı açılırsa (aşağıda) aynı numara ikinci kez kaydedilmez.
- **Seed:** aynı seed + aynı istek sırası = aynı davranış dizisi. ERP Simulator yeniden başlayınca dizi baştan başlar.
- **Log:** her istek seçilen davranışla loglanır: `ERP request #12 invoice=INV-2026-0001 behavior=Busy status=429 retryAfter=17s`

### Webhook'lar

Kaydedilen her fatura (`Success`, `SaveThenError`, `LateResponse`) için iki webhook event planlanır ve faturayla aynı transaction'da
`webhook_deliveries` tablosuna yazılır: önce `invoice.received` (kayıttan 2–10 sn sonra), sonra `invoice.approved` (%80) ya da
`invoice.rejected` (%20, `reason` ile; `invoice.received`'dan 2–20 sn sonra). Arka plandaki gönderici, zamanı gelen event'i
Invoice Service'in `POST /api/v1/erp-webhooks` adresine gönderir.

- Body: `event_id`, `event_type`, `invoice_number`, `erp_reference`, `occurred_at`, `invoice.rejected` event'inde `reason`.
- İmza: `X-Erp-Signature` = `HMAC-SHA256(secret, "{X-Erp-Timestamp}.{raw body}")`, küçük harfli hex; timestamp Unix saniye.
- 5 sn içinde 2xx gelmezse aynı event, bir önceki gönderimin başlangıcından 5, 10, 20, 40 ve 80 sn sonra en fazla 5 kez
  daha gönderilir (retry); sonra `Failed`.
- Bilerek çıkarılan sorunlar (oranlar birbirinden bağımsız): çift gönderim (duplicate; event başına %10, aynı `event_id`), sıra
  karışması (order mix; %15, karar önce gönderilir; oluşma zamanları gerçek sırada kalır), kayıp karar (lost decision; %5, hiç gönderilmez),
  sahte event (fake; %5, yanlış secret ile imzalı karar), eski event (replay; %5, asıl event teslim edildikten sonra 10 dk önceki
  timestamp ile ve ona göre geçerli imzayla). Fake ve replay event'ler 4xx ile reddedilince tekrar gönderilmez.
- Her gönderim loglanır: `Webhook send event=… type=invoice.received invoice=FTR-000042 kind=Normal attempt=1/6 http=200 outcome=Delivered …`

### Ayarlar

[`erp-simulator/src/ErpSimulator/appsettings.json`](erp-simulator/src/ErpSimulator/appsettings.json) ve
[`appsettings.Docker.json`](erp-simulator/src/ErpSimulator/appsettings.Docker.json) — container'a mount edilir, değişiklikten sonra `docker compose restart erp-simulator`.

```json
"Simulator": {
  "Seed": 42,
  "Rates": { "Success": 60, "Busy": 15, "ServerError": 10, "SaveThenError": 5, "LateResponse": 10 },
  "LateResponseDelaySeconds": 30,
  "RetryAfterMinSeconds": 5,
  "RetryAfterMaxSeconds": 30,
  "RetryAfterFormat": "Seconds",
  "IdempotentInvoices": false
}
```

- Bu on bir değerin hepsi zorunludur; kodda varsayılan yoktur. Biri eksikse uygulama başlamaz ve hangisinin eksik olduğunu
  yazar (ör. `Simulator:Rates:Success is missing from the settings file`).
- Oranların toplamı tam 100 olmak zorundadır (her oran 0–100 arası bir sayı). Değilse uygulama açılmaz ve gelen toplamı
  yazar; örneğin diğerlerine dokunmadan yalnızca `Busy` 100 yapılırsa:
  `Simulator:Rates must add up to exactly 100 (was 185: Success=60 Busy=100 ServerError=10 SaveThenError=5 LateResponse=10).`
- `Success` 100, hata oranlarının hepsi 0 ise ERP Simulator kusursuz bir ERP gibi davranır.
- **`IdempotentInvoices`** (varsayılan `false`): `false` iken tekrarlar engellenmez (yukarıdaki davranış). `true` iken
  aynı fatura numarasıyla gelen istekler sırayla işlenir (ilk isteğin kaydı tamamlanana kadar ikincisi bekler) ve numara
  zaten kayıtlıysa yeniden kaydedilmez: içerik aynıysa mevcut referansla `202` (davranış seçilmez, logda
  `behavior=Duplicate`), farklıysa `409`. Kontrol ve kayıt, fatura numarasından üretilen PostgreSQL transaction
  lock'u (`pg_advisory_xact_lock`) altında yapılır; lock kayıt commit edilene kadar tutulur. Veritabanına unique index
  eklenmedi: eski çift kayıtlar silinmez ve ayar geri kapatılabilir. Koruma, aynı veritabanını kullanan bütün
  gönderim yollarının bu kilide uymasını gerektirir; devam eden istekler bitmeden mod değiştirilmemelidir.
- Açılışta ayarlar loglanır: `Simulator settings: seed=42 success=60% busy=15% ... (total=100) ...`
- **`Webhooks`** bölümü (hepsi zorunlu, her birinin yanında Türkçe açıklama): `Enabled` (varsayılan `true`; `false` iken
  event planlanmaz, yalnızca kendi event'ini gönderen testler için), `TargetUrl` (Docker'da `appsettings.Docker.json`'da),
  `Secret` (Invoice Service'teki `ErpWebhooks:Secret` ile aynı; yalnızca yerel geliştirme değeri), `TimeoutSeconds` (5),
  `RetryDelaysSeconds` (5, 10, 20, 40, 80), `FirstEvent…`/`SecondEvent…` (2–10 / 2–20 sn), `ApprovalRate` (80),
  `RejectReasons`, `MaxConcurrentSends`, `PollMilliseconds` ve `Problems` (`DuplicateRate` 10, `OrderMixRate` 15,
  `LostDecisionRate` 5, `FakeRate` 5, `ReplayRate` 5, `ReplayAgeSeconds` 600). Açılışta `Webhook settings: …` ve
  `Webhook problems: …` loglanır.

Tek seferlik değişiklik ortam değişkeniyle de yapılabilir (toplam yine 100 olmalı):

```powershell
$env:Simulator__Rates__Success=0; $env:Simulator__Rates__Busy=100; $env:Simulator__Rates__ServerError=0; $env:Simulator__Rates__SaveThenError=0; $env:Simulator__Rates__LateResponse=0; docker compose up -d --force-recreate erp-simulator
```

---

## Invoice Service

.NET 10, ASP.NET Core Minimal API, kendi PostgreSQL veritabanı (`invoice-db`).

Fatura isteğin içinde ERP'ye gönderilmez: fatura ve Outbox kaydı (`erp_outbox`) aynı transaction'da
yazılır, istek hemen `202` döner. Arka plandaki `OutboxWorker` kuyruktan sırası gelenleri ERP Simulator'a gönderir,
hataya göre bekleyip tekrar dener ve sonucu yazar (Outbox Pattern). Amaç, faturanın kaydedilip gönderim işinin unutulmasını
önlemek: iki kayıt birlikte yazılır ya da ikisi de geri alınır. Bu yerel transaction, ERP'deki kaydı kapsamaz;
uzaktaki çift kayıt sorunu ayrıca ele alınır.

ERP'nin gönderdiği webhook event'leri (`invoice.received`, `invoice.approved`, `invoice.rejected`) `POST /api/v1/erp-webhooks` ile
gelir; imza doğrulanır, event `erp_webhook_events` tablosuna bir kez yazılır ve faturanın durumunun yalnızca ileri götürülmesi amaçlanır.

### Veri

- **`invoices`**: `invoice_number`, `customer_code`, `amount`, `currency`, `invoice_date`, `status`, `erp_reference`,
  `reject_reason`, `last_error`, `send_attempt_count`, `created_at`, `updated_at`.
  - Fatura numarasını servis üretir: PostgreSQL sequence → `FTR-000001`. Body'de gönderilen `invoiceNumber` yok sayılır.
  - `status`: `Bekliyor` → `Gönderildi` ya da `Başarısız`; ERP webhook'larıyla `Gönderildi` → `İşleme Alındı` →
    `Onaylandı` / `Reddedildi` (Gönderildi'den doğrudan karar da olur). Altı değer veritabanında check constraint ile
    sınırlı. `Onaylandı` ve `Reddedildi` kesin durumdur. `Başarısız`: bütün denemeler tükendiğinde ya da ERP Simulator 429
    dışında bir 4xx döndüğünde; yalnızca resend onu yeniden kuyruğa alır.
  - `reject_reason`: `invoice.rejected` event'indeki `reason`; yalnızca `Reddedildi` faturada dolu.
  - `send_attempt_count`: faturanın ömrü boyunca yapılan deneme sayısı; resend'de sıfırlanmaz.
- **`erp_outbox`**: faturanın Outbox kaydı, fatura başına bir satır (`invoice_number` unique).
  `id`, `invoice_number`, `status` (`Bekliyor` / `Tamamlandı` / `Başarısız`), `attempt_count`, `next_attempt_at`,
  `last_error`, `created_at`, `processed_at`. Eklenen kolonlar:
  - `locked_until`: sahipliğin bitiş zamanı; worker ölürse kayıt lease süresi dolunca yeniden alınabilir.
  - `locked_by`: kaydı alan servis instance'ı; hangi worker'ın çalıştığını izlemek için.
  - `claim_token`: her alımda yeni kimlik; eski alımın sonucunun yeni alımın sonucunu ezmesini önlemek için.
- **`erp_webhook_events`**: gelen her geçerli event bir satır (`event_id` birincil anahtar). `event_type`, `invoice_number`,
  `erp_reference`, `occurred_at`, `received_at` (ilk geliş), `processed_at` (faturaya işlendiği an; yalnızca `İşlendi`'de dolu), `status` (`İşlendi` / `Bekliyor` / `Yok Sayıldı`),
  `payload` (raw body). Eklenen kolonlar:
  - `delivery_count`: aynı event'in kaç kez geldiği; tekrar gelen event yeniden işlenmez, yalnızca sayılır.
  - `ignore_reason`: Yok Sayıldı'nın nedeni (`Geri Götürüyor`, `Kesin Durumda`, `İlerletmiyor`, `Referans Farklı`).

### Endpoint'ler

| Endpoint | Davranış |
|---|---|
| `POST /api/v1/invoices` | Body: `customerCode`, `amount`, `currency`, `invoiceDate`. Fatura `Bekliyor` durumunda ve `erp_outbox` kaydıyla aynı transaction'da yazılır, `202`. ERP Simulator bu istekte çağrılmaz. Geçersiz body `400` (tutarda virgülden sonra en fazla iki basamak; sondaki sıfırlar da sayılır), hiçbir şey kaydedilmez. |
| `POST /api/v1/invoices/{invoiceNumber}/resend` | Yalnızca `Başarısız` fatura için. ERP Simulator'a gitmez: Outbox kaydını sıfırlar (`Bekliyor`, 0 deneme, hemen) ve faturayı `Bekliyor` yapar, `202`. `Başarısız` değilse `409`, yoksa `404`. Aynı anda iki resend gelirse biri `202`, diğeri `409` alır. |
| `GET /api/v1/invoices?status=Bekliyor` | O durumdaki faturalar (altı durumdan biri); `status` verilmezse hepsi, geçersizse `400`. Testlerde kuyruğun boşalmasını beklemek için. |
| `GET /api/v1/invoices/{invoiceNumber}` | Faturanın servisteki hali (`200`, `rejectReason` dahil) ya da `404`. |
| `POST /api/v1/erp-webhooks` | ERP webhook event'i (aşağıda). İmza header'ları yok/yanlış ya da timestamp 5 dk'dan eski veya ileri: `401`, kaydedilmez. İmza doğru ama body geçersiz: `400`; 64 KB'tan büyük body: `413`. Event 4 sn içinde işlenemezse `503` (ERP tekrar gönderir). Aksi halde `200` + `{eventId, status, repeat}`. |

### Outbox Worker

- Worker kuyruktan zamanı gelmiş (`next_attempt_at` geçmiş, lock'u olmayan) kayıtları tek bir SQL cümlesiyle alır
  (`FOR UPDATE SKIP LOCKED`); kayda `locked_until`, `locked_by`, yeni bir `claim_token` yazar ve deneme sayısını
  gönderimden **önce** artırır. Her servis instance'ı aynı anda en fazla `MaxConcurrentSends` (10) gönderim yapar.
- Retry kuralları (`RetryPolicy`):

  | ERP Simulator cevabı | Ne olur |
  |---|---|
  | ERP referansı içeren `202` | `Gönderildi` + `erp_reference`, Outbox `Tamamlandı` |
  | `429` | `Retry-After` kadar beklenir (saniye ya da tarih biçimi); jitter eklenmez |
  | `500`, 10 sn timeout, ulaşılamama | 2, 4, 8 … sn + 0–1 sn rastgele jitter; planlanan toplam bekleme en fazla 60 sn |
  | 429 dışında 4xx | Hemen `Başarısız`, tekrar denenmez |
  | 10. deneme de başarısız | Son ERP sorgusunda kayıt bulunursa `Gönderildi`; bulunamaz veya sorgulanamazsa iki kayıt da `Başarısız` |

- **Çift kayıt kontrolü:** fatura daha önce gönderilmeye çalışıldıysa Invoice Service POST'tan önce ERP Simulator'a `GET` ile sorar:
  varsa referansı alır (POST yok), açıkça `404` ise gönderir, sorulamazsa göndermez ve sonra tekrar dener. Hakları
  bitince faturayı `Başarısız` yapmadan önce bir kez daha sorar.
- **Invoice Service öldürülürse:** fatura ve Outbox veritabanında kalır. Lock, kaydın alındığı andan itibaren `LockSeconds`
  (60 sn) geçince dolar ve kayıt yeniden alınabilir. Sonuç yalnızca kayıt hâlâ o alımın `claim_token`'ını taşıyorsa
  yazılır. Son denemesi yarıda kalmış kayıt yeniden POST edilmez; yalnızca ERP'ye sorulur.
- **İki instance'ın koordinasyonu:** `SKIP LOCKED` aynı satırın birlikte alınmasını önler; süreli sahiplik (lease), transaction
  bittikten sonra da kaydı diğer worker'dan korur. POST öncesinde token ve süre tekrar kontrol edilir. Ancak bu kontrol
  ile HTTP çağrısı atomik değildir; arada uzun süre duran bir worker için mutlak gönderim engeli sayılmaz.
- **Exponential Backoff ve Jitter:** 429 ve erişilemeyen ERP denemeleri de sayılır; sonraki 500'ün beklemesi toplam deneme numarasına göre
  hesaplanır. Jitter, birlikte hata alan faturaların aynı anda yeniden yüklenmesini azaltır. Deneme hakları tükenirse
  resend ile yeni bir tur başlatılabilir; fatura üzerindeki ömür boyu sayaç sıfırlanmaz.
- Her deneme loglanır:
  `ERP send invoice=FTR-000042 attempt=3/10 worker=… claim=1a2b3c4d check=notFound outcome=Retry http=500 … wait=8.412s reason=…`
- **Bilinen sınır (Gün 3):** ilk POST ERP'de henüz kaydedilmeden timeout olursa sonraki GET `404` dönebilir ve ikinci POST
  çift kayıt oluşturabilir; ERP Simulator'da `IdempotentInvoices=true` bunu alıcı tarafta önlemek için eklendi.

### ERP webhook'ları

- **İmza:** `X-Erp-Timestamp` ve `X-Erp-Signature` body JSON'a çevrilmeden raw byte'lar üzerinden doğrulanır; imza sabit
  zamanlı karşılaştırılır (`CryptographicOperations.FixedTimeEquals`). 401'in nedeni yalnızca loga yazılır.
- **Tekrar (duplicate):** event `INSERT … ON CONFLICT (event_id)` ile yazılır; aynı event'in (paralel gelse de) yalnızca bir kez işlenmesi
  amaçlanır; sonrakiler `200` alır ve `delivery_count`'u artırır (kontrol listesi 8'de 10 paralel istekte event bir kez işlendi).
- **Uygulama:** fatura satırına `SELECT … FOR UPDATE` ile lock alınır. İleri götüren event uygulanır; `erp_reference` farklıysa
  (uyarı logu) ya da durumu ilerletmiyorsa event `Yok Sayıldı`, fatura değişmez.
- **Faturadan önce gelen event:** fatura henüz `Gönderildi` değilse event `Bekliyor` saklanır. Outbox faturayı `Gönderildi`
  yaptığı transaction'da bekleyen event'leri geliş sırasıyla işler; aynı row lock ile ikisinin iç içe geçmemesi amaçlanır.
- **Cevap süresi (görev: 5 sn):** event kendi DI scope'unda işlenir; cevap en geç `ResponseBudgetMilliseconds` (4000 ms)
  sonra döner. Bu sürede işlenemezse ya da fatura satırının lock'u `LockTimeoutMilliseconds` (2000 ms) içinde alınamazsa
  `503` dönülür ve ERP event'i tekrar gönderir. PostgreSQL tarafında da `lock_timeout` ve `statement_timeout` açıktır.
  `503`'ten sonra iş yine de commit olabilir; o durumda tekrar gelen event tekrar sayılır, iki kez işlenmez.
- Loglar: `ERP webhook stored|repeat|applied-after-send event=… invoiceStatus=Gönderildi->İşleme Alındı …`,
  `ERP webhook rejected http=401 reason=bad-signature …`, `ERP webhook rejected http=503 reason=lock-timeout|timeout …`

### Ayarlar

[`invoice-service/src/InvoiceService/appsettings.json`](invoice-service/src/InvoiceService/appsettings.json) — her
değerin yanında ne işe yaradığı ve görevden mi geldiği, uygulama tercihi mi olduğu yorum olarak yazılı. Hepsi zorunludur;
eksik ya da kurala aykırıysa servis açılmaz ve nedenini yazar. Değişiklikten sonra `docker compose up -d --build invoice-service`.

| Ayar | Değer | Kaynak |
|---|---|---|
| `Erp:BaseUrl` | `http://localhost:5080` | Docker'da `appsettings.Docker.json`: `http://erp-simulator:8080` |
| `Erp:TimeoutSeconds` | `10` | Görev (`HttpClient`'ın varsayılanı 100 sn; ERP Simulator'da `LateResponse` süresi 30 sn) |
| `Outbox:MaxConcurrentSends` | `10` | Görev; servis instance'ı başına |
| `Outbox:MaxAttempts` | `10` | Görev |
| `Outbox:MaxBackoffSeconds` | `60` | Görev; jitter dahil tavan |
| `Outbox:MaxJitterMilliseconds` | `1000` | Uygulama tercihi |
| `Outbox:BackoffMarginMilliseconds` | `0` | Uygulama tercihi; tavanın altında bırakılan pay |
| `Outbox:LockSeconds` | `60` | Uygulama tercihi; `3 × TimeoutSeconds`'tan uzun olmak zorunda |
| `Outbox:IdleDelayMilliseconds` | `250` | Uygulama tercihi; kuyrukta iş yokken bekleme |
| `ErpWebhooks:Secret` | yerel geliştirme değeri | Görev: ayar dosyasından; ERP Simulator'daki `Webhooks:Secret` ile aynı olmalı, en az 32 bayt |
| `ErpWebhooks:ToleranceSeconds` | `300` | Görev: 5 dk'dan eski timestamp `401`; aynı sınır ileri tarihli timestamp'e de uygulanır (ek kural) |
| `ErpWebhooks:MaxBodyBytes` | `65536` | Uygulama tercihi; büyük body imza hesaplanmadan `413` |
| `ErpWebhooks:ResponseBudgetMilliseconds` | `4000` | Görev: her event'e 5 sn içinde cevap; 5000'den küçük olmak zorunda |
| `ErpWebhooks:LockTimeoutMilliseconds` | `2000` | Uygulama tercihi; fatura satırının lock'unu bekleme sınırı, `ResponseBudgetMilliseconds`'tan küçük |

Açılışta ayarlar loglanır: `ERP settings: …`.

### İkinci instance

`docker-compose.yml`'de aynı veritabanını kullanan ikinci bir instance var (`invoice-service-2`, port `5091`, profil
`iki-kopya`); düz `docker compose up` onu başlatmaz:

```bash
docker compose --profile iki-kopya up -d invoice-service-2
```

---

## Testler

| Ne | Komut |
|---|---|
| Unit testler | `dotnet test erp-simulator` ve `dotnet test invoice-service` |
| Manuel testler — Gün 4 kontrol listesi, adım ve ek testleri | [`manual-tests/gun4/`](manual-tests/gun4/) |
| Manuel testler — Gün 3 kontrol listesi (Gün 4'ten beri ERP Simulator'ı webhook göndermeden çalıştırır) | [`manual-tests/gun3/`](manual-tests/gun3/README.md) |
| Manuel testler — ERP Simulator | [`manual-tests/gun1/`](manual-tests/gun1/README.md) |
| ERP Simulator veritabanı / logları | `.\manual-tests\gun1\db.ps1`, `.\manual-tests\gun1\loglar.ps1` |
| Invoice Service veritabanı | `.\manual-tests\gun2\db.ps1` |
| ERP Simulator uçtan uca kontrol (bash) | `./scripts/erp-simulator-checklist.sh` |
| ERP Simulator dağılım ölçümü (bash) | `./scripts/erp-simulator-distribution.sh <adet>` |

`manual-tests/gun2/` içindeki kontrol listesi script'leri Gün 2'deki eşzamanlı gönderimi (`201`, resend'in doğrudan
göndermesi) test eder; [gun-2](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-2) tag'inde çalıştırılmalıdır.
Gün 3 script'leri onun yardımcılarını (`_common.ps1`, `db.ps1`) kullanmaya devam eder.

Manuel deneme: Swagger UI (yukarıdaki adresler) veya `.http` dosyaları
([ERP Simulator](erp-simulator/src/ErpSimulator/ErpSimulator.http), [Invoice Service](invoice-service/src/InvoiceService/InvoiceService.http));
loglar için `docker compose logs -f erp-simulator` / `docker compose logs -f invoice-service`.
Script'ler engellenirse önce `Set-ExecutionPolicy -Scope Process Bypass`.

---

## Gün 4 — ERP'den Gelen Haberler

Bugünün işi: ERP Simulator kaydettiği her fatura için imzalı webhook'lar gönderiyor ve bilerek sorun çıkarıyor (yukarıda
[Webhook'lar](#webhooklar)); Invoice Service bu event'leri doğrulayıp faturaya işliyor (yukarıda [ERP webhook'ları](#erp-webhookları)).
Fatura durumları altıya çıktı, `reject_reason` ve `erp_webhook_events` eklendi. Önce Gün 3'teki yuvarlama bulgusu kapatıldı:
iki uygulama da virgülden sonra ikiden fazla basamağı olan tutarı (sondaki sıfırlar dahil) `400` ile reddediyor.
Invoice Service her event'e 5 sn içinde cevap veriyor (gerekirse `503`). Docker ayarları `appsettings.Docker.json`'a taşındı.

Kontrol listesi ve ek testler: [`manual-tests/gun4/`](manual-tests/gun4/) (`.\manual-tests\gun4\kontrol-listesi.ps1`
8 maddeyi sırayla çalıştırır; `ek-kabul-kurallari.ps1`, `ek-cevap-suresi.ps1`, `ek-fatura-servisi.ps1`,
`ek-simulator-kararlari.ps1` ek kanıtlar).

### Son doğrulama — 2 Ekim 2026

Sekiz test tek seferde çalıştırıldı ve **9,3 dakikada geçti**. Bunlar bu koşunun sonuçlarıdır; başka koşullarda ya da başka bir koşuda farklı sonuç çıkmayacağını göstermez.

| # | Senaryo | Sonuç |
|---|---|---|
| 1 | Üç ondalıklı tutar | `1.234`, `1.230`, `1.2300` iki uygulamada da `400`, kayıt yok; `1.23`, `1.20` kabul |
| 2 | Bütün oranlar 0, 100 fatura | Hepsi Onaylandı/Reddedildi; Reddedildi'lerin `reject_reason`'ı dolu; 200 event tabloda tam bir kez |
| 3 | Varsayılan oranlar, 500 fatura | Aşağıda |
| 4 | Sıra karışması %100, 20 fatura | 20 kesin durumda; sonradan gelen 20 `invoice.received` Yok Sayıldı |
| 5 | Invoice Service 125 sn kapalı | Kapalıyken teslim edilen event görülmedi; 1 event kapanmadan önce, 39 event açılınca retry ile geldi; 20 fatura kesin durumda |
| 6 | Geç cevap %100, 10 fatura | 10'unda ilk event fatura Gönderildi olmadan geldi (log ve veritabanı); hepsi kesin durumda |
| 7 | Yanlış imza, header yok, 10 dk eski timestamp | Üçü `401`; tabloda bulunmadı |
| 8 | Aynı event 10 kez paralel | Biri işledi, 9'u tekrar (`delivery_count` 10); fatura bir kez ilerledi |

**500 fatura testi** (`FTR-021047 .. FTR-021546`):

| Durum | Sayı |
|---|---|
| Onaylandı | 367 |
| Reddedildi | 103 |
| Gönderildi ya da İşleme Alındı'da kalan fatura | 30 |
| ERP Simulator'ın karar event'ini hiç göndermediği fatura | 30 |
| 401 ile reddedilen sahte (fake) event | 20 |
| 401 ile reddedilen eski (replay) event | 31 |
| Tekrar geldiği için yeniden işlenmeyen event | 109 |
| Durumu geri götürdüğü için Yok Sayıldı olan event | 68 |
| Durumu geri giden fatura | 0 |

Kalan 30 fatura, kararı gönderilmeyen 30 faturayla numara numara karşılaştırıldı; listeler aynı çıktı. Yerel ham çıktı:
`manual-tests/output/gun4-kontrol-listesi-20261002-191117.log` (Git'e dahil değildir).

### Bilinen sınırlar

- **Servis kesintisi:** bu koşuda 125 sn'lik kesintiden sonra event'ler son denemede ulaştı. Deneme hakları tükenmeden
  Invoice Service erişilebilir olmazsa event `Failed` olur ve fatura kesin duruma geçmez.
- **Cevap süresi:** 5 sn sınırı servisin kendi işini kapsar; servis hiç çalışmıyorsa ya da donmuşsa cevap gelmez, bu durumda
  ERP'nin tekrar gönderimi devreye girer.
- **Kaydedilmeyen istekler:** `401`'e ek olarak `400` (geçersiz body) ve `413` (64 KB üstü) alan event'ler de tabloya yazılmaz;
  nedenleri servis loguna yazılır.

---

## Günler

| Tag | Gün | O günün hali |
|---|---|---|
| `gun-1` | ERP Simulator | [tree/gun-1](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-1) |
| `gun-2` | Invoice Service'in ilk sürümü | [tree/gun-2](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-2) |
| `gun-3` | Güvenli Gönderim | [tree/gun-3](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-3) |
| `gun-4` | ERP'den Gelen Haberler | [tree/gun-4](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-4) |
