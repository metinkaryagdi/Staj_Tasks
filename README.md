# Staj_Tasks

Fatura entegrasyonu üzerine staj projesi: Invoice Service ve ona hata üreterek cevap veren, sonra faturanın sonucunu
imzalı webhook'larla bildiren ERP Simulator.

| Uygulama | Klasör | Ne yapar |
|---|---|---|
| ERP Simulator | `erp-simulator/` | Faturaları kabul eden ERP'yi taklit eder; her isteğe seed'li rastgele bir hata davranışı uygular; kaydettiği faturalar için Invoice Service'e imzalı webhook gönderir (bilerek sorunlu) |
| Invoice Service | `invoice-service/` | Faturayı ve Outbox kaydını birlikte kaydeder; arka planda ERP'ye gönderir; ERP'den gelen webhook event'lerini doğrulayıp faturaya işler; belirli aralıklarla kendi kayıtlarını ERP'ninkiyle karşılaştırır (mutabakat), düzeltebildiğini düzeltir, düzeltemediğini raporlar |

İki uygulama da Domain / Application / Infrastructure / Api olarak dört katmana ayrılmıştır; katmanlar, port'lar ve
hangi kodun nerede olduğu [ARCHITECTURE.md](ARCHITECTURE.md)'de.

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
| `GET /api/v1/invoices/{invoiceNumber}` | `200` + `registered`, `erpReference` (ilk kayıt), `recordCount`, `records[]`, `decision` (`none` / `received` / `approved` / `rejected`), `reason` (yalnızca `rejected`), `decidedAt`. Karar, ilk kaydın olaylarından türetilir ve haberi hiç gönderilmemiş olsa bile zamanı gelince görünür. Kayıt yoksa `404`. Hata üretmez. |
| `GET /api/v1/invoices?from=…&to=…&page=1&pageSize=100` | `receivedAt`'i `[from, to)` içinde kalan kayıtlar, `(receivedAt, id)` sıralı ve sayfalı: `{page, pageSize, totalCount, items[]}`. `from` ve `to` zorunlu, `from < to`; `pageSize` en çok 500 (üstü `400`, kırpılmaz). Çift kayıtlar ayrı satırdır. |

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

[`erp-simulator/src/ErpSimulator.Api/appsettings.json`](erp-simulator/src/ErpSimulator.Api/appsettings.json) ve
[`appsettings.Docker.json`](erp-simulator/src/ErpSimulator.Api/appsettings.Docker.json) — container'a mount edilir, değişiklikten sonra `docker compose restart erp-simulator`.

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

Haberi hiç gelmeyen ya da başka nedenle ERP'den ayrışan faturalar için mutabakat işi servisin içinde belirli aralıklarla
çalışır (aşağıda [Mutabakat](#mutabakat)).

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
  - `ignore_reason`: Yok Sayıldı'nın nedeni (`Geri Götürüyor`, `Kesin Durumda`, `İlerletmiyor`, `Referans Farklı`, `Fatura Yok`).
- **`reconciliation_runs`**: bir mutabakat çalışması. `id`, `started_at`, `finished_at`, `status` (`Çalışıyor` / `Tamamlandı` /
  `Başarısız`), `checked_count` (karşılaştırılan fatura numarası), `fixed_count`, `reported_count`, `error`. Ek kolon yok; durumla
  `finished_at` / `error` tutarlılığı check constraint ile korunur.
- **`reconciliation_findings`**: çalışmanın bulduğu fark. `id`, `run_id`, `invoice_number`, `finding_type`, `action`
  (`Düzeltildi` / `Raporlandı`), `details`, `created_at`. `Düzeltildi` yalnızca düzeltilen üç türde olabilir (check constraint).

### Endpoint'ler

| Endpoint | Davranış |
|---|---|
| `POST /api/v1/invoices` | Body: `customerCode`, `amount`, `currency`, `invoiceDate`. Fatura `Bekliyor` durumunda ve `erp_outbox` kaydıyla aynı transaction'da yazılır, `202`. ERP Simulator bu istekte çağrılmaz. Geçersiz body `400` (tutarda virgülden sonra en fazla iki basamak; sondaki sıfırlar da sayılır), hiçbir şey kaydedilmez. |
| `POST /api/v1/invoices/{invoiceNumber}/resend` | Yalnızca `Başarısız` fatura için. ERP Simulator'a gitmez: Outbox kaydını sıfırlar (`Bekliyor`, 0 deneme, hemen) ve faturayı `Bekliyor` yapar, `202`. `Başarısız` değilse `409`, yoksa `404`. Aynı anda iki resend gelirse biri `202`, diğeri `409` alır. |
| `GET /api/v1/invoices?status=Bekliyor` | O durumdaki faturalar (altı durumdan biri); `status` verilmezse hepsi, geçersizse `400`. Testlerde kuyruğun boşalmasını beklemek için. |
| `GET /api/v1/invoices/{invoiceNumber}` | Faturanın servisteki hali (`200`, `rejectReason` dahil) ya da `404`. |
| `POST /api/v1/reconciliation-runs` | Mutabakatı elle başlatır: `202` + çalışma (`Çalışıyor`), çalışma arka planda sürer. Başka bir çalışma sürüyorsa (zamanlanmış, elle ya da servisin diğer kopyasında) `409`. |
| `GET /api/v1/reconciliation-runs` | Çalışmalar, en yeniden eskiye (bulgusuz). |
| `GET /api/v1/reconciliation-runs/{id}` | `{ run, findings[] }` ya da `404`. |
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

### Mutabakat

`ReconciliationWorker` ayardaki aralıkta çalışır (varsayılan 60 dk; ilk çalışma servis açıldıktan bir aralık sonra); aynı iş
`POST /api/v1/reconciliation-runs` ile elle de başlar. Çalışma son `LookbackHours` saatin faturalarını ERP Simulator'ın
kayıtlarıyla karşılaştırır. Önce her şeyi okur, sonra yazar: ERP Simulator'a ulaşılamazsa çalışma `Başarısız` olur ve hiçbir fatura
değişmemiştir.

| Bulgu türü | Eylem |
|---|---|
| `Takılı Fatura`: `Gönderildi` / `İşleme Alındı`'da `StuckAfterMinutes`'tan uzun kalmış | ERP'ye kararı sorulur, haberlerle aynı kurallara göre işlenir (**Düzeltildi**) |
| `Başarısız Ama ERP Kayıtlı` | ERP'deki referansla `Gönderildi` olur, karar varsa o da işlenir; `erp_outbox` kaydı `Tamamlandı` (**Düzeltildi**) |
| `Tanınmayan Haber`: serviste olmayan faturaya ait, `UnknownEventAfterMinutes`'tan eski bekleyen event | `Yok Sayıldı` (`Fatura Yok`) (**Düzeltildi**) |
| `Serviste Yok`: ERP'de var, serviste hiç yok | Raporlandı |
| `ERP Çift Kayıt`: ERP'de birden fazla kaydı olan fatura | Raporlandı |
| `Alan Farkı`: tutar, para birimi, müşteri kodu ya da `erp_reference` farklı | Raporlandı |
| `ERP Kaydı Yok`: serviste `Gönderildi` ya da sonrası, ERP'de kayıt yok (görevdeki tabloda yok, eklendi) | Raporlandı |

- **Aynı anda tek çalışma:** PostgreSQL advisory lock. Zamanlanmış çalışma, elle başlatma ve servisin ikinci kopyası aynı kilidi kullanır;
  kilit başkasındaysa `POST` `409` alır, zamanlanmış tur atlanır. Kilit tablodaki bir satıra değil bağlantıya bağlıdır: kopya durursa ya da
  çökerse veritabanı bırakır.
- **Haberle çakışma:** bir fatura düzeltilirken satırının lock'u (`SELECT … FOR UPDATE`) tutulur; event ve resend de aynı lock'u alır.
  Lock alındıktan sonra fatura planın gördüğü durumda değilse (event ya da resend araya girdiyse) o fatura bırakılır.
- Düzeltilmeyenler hangi tarafın doğru olduğunu bilmeyi gerektirir; bu yüzden yalnızca raporlanır. Ayrıntı: [ARCHITECTURE.md](ARCHITECTURE.md).

### Ayarlar

[`invoice-service/src/InvoiceService.Api/appsettings.json`](invoice-service/src/InvoiceService.Api/appsettings.json) — her
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
| `Outbox:LockSeconds` | `60` | Uygulama tercihi; `3 × TimeoutSeconds`'tan uzun olmak zorunda |
| `Outbox:IdleDelayMilliseconds` | `250` | Uygulama tercihi; kuyrukta iş yokken bekleme |
| `ErpWebhooks:Secret` | yerel geliştirme değeri | Görev: ayar dosyasından; ERP Simulator'daki `Webhooks:Secret` ile aynı olmalı, en az 32 bayt |
| `ErpWebhooks:ToleranceSeconds` | `300` | Görev: 5 dk'dan eski timestamp `401`; aynı sınır ileri tarihli timestamp'e de uygulanır (ek kural) |
| `ErpWebhooks:MaxBodyBytes` | `65536` | Uygulama tercihi; büyük body imza hesaplanmadan `413` |
| `ErpWebhooks:ResponseBudgetMilliseconds` | `4000` | Görev: her event'e 5 sn içinde cevap; 5000'den küçük olmak zorunda |
| `ErpWebhooks:LockTimeoutMilliseconds` | `2000` | Uygulama tercihi; fatura satırının lock'unu bekleme sınırı, `ResponseBudgetMilliseconds`'tan küçük |
| `Reconciliation:IntervalMinutes` | `60` | Uygulama tercihi; testlerde `Reconciliation__IntervalMinutes` ortam değişkeniyle 1'e çekilir; en çok 10080 (`docker-compose.yml`'de geçişi var). Daha kısası, karar event'i hiç gelmeyen faturaları da düzelteceği için Gün 4'ün sayımını değiştirir |
| `Reconciliation:LookbackHours` | `24` | Görev: son 24 saat; en çok 8760 |
| `Reconciliation:StuckAfterMinutes` | `2` | Görev: `Gönderildi` / `İşleme Alındı`'da bundan uzun kalan fatura |
| `Reconciliation:UnknownEventAfterMinutes` | `60` | Görev: tanınmayan faturanın bekleyen event'i bundan eskiyse |

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
| Manuel testler — Gün 5 kontrol listesi (2-9. maddeler; 1. madde Gün 3 ve Gün 4 listeleridir), adım ve ek test | [`manual-tests/gun5/`](manual-tests/gun5/) |
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
([ERP Simulator](erp-simulator/src/ErpSimulator.Api/ErpSimulator.Api.http), [Invoice Service](invoice-service/src/InvoiceService.Api/InvoiceService.Api.http));
loglar için `docker compose logs -f erp-simulator` / `docker compose logs -f invoice-service`.
Script'ler engellenirse önce `Set-ExecutionPolicy -Scope Process Bypass`.

---

## Gün 5 — Mutabakat

Bugünün işi: Invoice Service belirli aralıklarla kendi kayıtlarını ERP Simulator'la karşılaştırıyor, düzeltebildiğini düzeltiyor,
düzeltemediğini raporluyor (yukarıda [Mutabakat](#mutabakat)). ERP Simulator bunun için `GET /api/v1/invoices/{n}` cevabında
faturanın kararını döndürüyor ve `GET /api/v1/invoices?from&to` ile kayıtlarını sayfalı listeliyor (yukarıda
[Endpoint'ler](#endpointler)). İki yeni tablo (`reconciliation_runs`, `reconciliation_findings`) ve `ignore_reason`'a `Fatura Yok` eklendi.
Önce kod sadeleştirildi: iki uygulama katmanlı yapıya alındı, açıklamalar kısaltıldı, tek ölçüm için eklenmiş ayar kaldırıldı
([ARCHITECTURE.md](ARCHITECTURE.md)); Gün 3 ve Gün 4 listeleri sonrasında da aynı sonucu verdi.

Kontrol listesi ve ek test: [`manual-tests/gun5/`](manual-tests/gun5/) (`.\manual-tests\gun5\kontrol-listesi.ps1` 2-9. maddeleri sırayla
çalıştırır; 1. madde `gun3` ve `gun4` listeleridir; `ek-haber-yarisi.ps1` ek kanıt).

### Son doğrulama — 5 Ekim 2026

Gün 3 (7/7, 21,9 dk), Gün 4 (8/8, 9,3 dk) ve Gün 5 (2-9, 12,3 dk) listeleri Gün 5 kodunda tek seferde çalıştırıldı ve hepsi geçti.
Bunlar bu koşunun sonuçlarıdır; başka koşullarda aynı sonucun çıkacağını göstermez.

| # | Senaryo | Sonuç |
|---|---|---|
| 1 | Sadeleştirmeden sonra Gün 3 ve Gün 4 listeleri | İkisi de baştan sona geçti (yukarıdaki süreler) |
| 2 | Varsayılan oranlarla 500 fatura, haberler bitince mutabakat | Mutabakattan önce 30 fatura `Gönderildi` / `İşleme Alındı`'da kalmıştı; ERP Simulator'ın karar event'ini göndermediği fatura sayısı da 30. Mutabakat 30 fatura düzeltti (aynı faturalar), sonra kalan 0. Çalışma 24 saatlik pencerede 6.249 fatura karşılaştırdı; öncesinde önceki testlerin takılı faturalarını temizleyen bir çalışma yapıldı |
| 3 | ERP Simulator'a elle eklenen, serviste olmayan fatura | `Serviste Yok` raporlandı; iki tarafta değişiklik yok |
| 4 | ERP Simulator'da tutarı elle değiştirilen fatura | `Alan Farkı` (tutar: serviste 1250.50, ERP'de 1260.50) raporlandı; iki tarafta değişiklik yok |
| 5 | `IdempotentInvoices` kapalıyken elle ikinci gönderim | `ERP Çift Kayıt` raporlandı; ERP Simulator'da 2 kayıt kaldı, serviste fatura aynı |
| 6 | Serviste elle `Başarısız` yapılan, `erp_reference`'ı boşaltılan fatura | `Başarısız Ama ERP Kayıtlı` düzeltildi: `Gönderildi`, ERP'deki referans, `erp_outbox` `Tamamlandı` |
| 7 | Tanınmayan faturaya geçerli imzalı event, eşik 1 dk | Zamanlanmış çalışma 125 sn sonra event'i `Yok Sayıldı` (`Fatura Yok`) yaptı; serviste fatura oluşmadı |
| 8 | Servisin iki kopyası + elle başlatma | Kilit başka oturumdayken iki kopya da `409`; 30 eşzamanlı istekte 1 `202`, 29 `409`; hiçbir iki çalışmanın zaman aralığı üst üste binmedi |
| 9 | Mutabakat sürerken ERP Simulator ulaşılamaz | Çalışma `Başarısız` (10 sn zaman aşımı), hiçbir fatura değişmedi; ERP Simulator açılınca sonraki çalışma 5 faturanın 5'ini düzeltti |

**Ek test** (`ek-haber-yarisi.ps1`): fatura satırı 8 sn kilitliyken mutabakat başlatıldı ve kararın event'i servise gönderildi. Event iki kez
`503` (lock-timeout) aldı, sonra `200`; fatura tek kez doğru karara ilerledi. İki koşuda iki farklı sıra görüldü: mutabakat önce
(event `Yok Sayıldı`, `Kesin Durumda`) ve event önce (mutabakat faturaya dokunmadı). Yerel ham çıktılar:
`manual-tests/output/gun5-kontrol-listesi-20261005-110826.log` ve `gun5-ek-haber-yarisi.log` (Git'e dahil değildir).

### Bilinen sınırlar

- **Pencere:** servis tarafı son `LookbackHours` saatte oluşan faturalar ve ERP Simulator'ın listelediği numaralardır; pencerenin dışına
  kaçmış eski bir takılı fatura bir daha görülmez.
- **Aralık:** varsayılan 60 dk. Testler 1 dk'ya çeker; 1 dk'da mutabakat karar event'i gelmemiş faturaları da düzeltir ve Gün 4'ün 3. maddesinin
  sayımını (kalan fatura = karar event'i gönderilmeyen fatura) değiştirir.
- **9. madde:** ERP Simulator kapatılmadı, `docker pause` ile donduruldu; kesinti çalışmanın ERP'den ilk okumasında oluştu. Karar sorgusu
  aşamasındaki kesinti yalnızca unit testle doğrulandı.
- **Düzeltilmeyenler:** içeriği (tutar, para birimi, müşteri kodu, referans) ERP'den farklı fatura ERP'nin referansıyla ya da kararıyla
  ilerletilmez, yalnızca raporlanır.
- **Yorum gerektirenler:** `decision` ilk event zamanı gelince `received`, karar zamanı gelince `approved` / `rejected` döner; alan adları
  camelCase'tir (`decidedAt`); `pageSize` 500'ü aşarsa `400` döner; `ERP Kaydı Yok` türü görevdeki tabloda yoktur.
- **Ölçek:** düzeltmeler ve karar sorguları sıralıdır; çalışma listesi sayfalanmaz.

---

## Günler

| Tag | Gün | O günün hali |
|---|---|---|
| `gun-1` | ERP Simulator | [tree/gun-1](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-1) |
| `gun-2` | Invoice Service'in ilk sürümü | [tree/gun-2](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-2) |
| `gun-3` | Güvenli Gönderim | [tree/gun-3](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-3) |
| `gun-4` | ERP'den Gelen Haberler | [tree/gun-4](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-4) |
| `gun-5` | Mutabakat | [tree/gun-5](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-5) |
