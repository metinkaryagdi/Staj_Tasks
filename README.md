# Staj_Tasks

Fatura entegrasyonu üzerine staj projesi: Invoice Service, ona hata üreterek cevap veren ve faturanın sonucunu imzalı
webhook'larla bildiren ERP Simulator, ve sistemi izleyip müdahale etmek için operasyon ekranı.

| Uygulama | Klasör | Ne yapar |
|---|---|---|
| ERP Simulator | `erp-simulator/` | Faturaları kabul eden ERP'yi taklit eder; saniyede sınırlı sayıda isteği kabul eder; her isteğe seed'li rastgele bir hata davranışı uygular; kaydettiği faturalar için Invoice Service'e imzalı webhook gönderir (bilerek sorunlu) |
| Invoice Service | `invoice-service/` | Faturayı ve Outbox kaydını birlikte kaydeder; arka planda ERP'ye gönderir; ERP'den gelen webhook event'lerini doğrulayıp faturaya işler; belirli aralıklarla kendi kayıtlarını ERP'ninkiyle karşılaştırır (mutabakat), düzeltebildiğini düzeltir, düzeltemediğini raporlar. API'si webhook ve `/health` dışında Keycloak'ın verdiği JWT ile korunur |
| Keycloak | `keycloak/` | Kimlik doğrulama: kullanıcılar operasyon ekranına buradan giriş yapar, sipariş sistemi token'ı buradan alır; realm (roller, client'lar, test kullanıcıları) açılışta dosyadan kurulur ([Kimlik doğrulama](#kimlik-doğrulama)) |
| Operasyon Ekranı | `operations-ui/` | Faturaların ve mutabakatın durumunu veritabanına bakmadan gösterir; Başarısız faturaları tek tek ya da toplu yeniden kuyruğa alır, mutabakatı başlatır. Yalnızca Invoice Service'in API'siyle konuşur. Kullanıcı Keycloak'ta giriş yapar; ekran kullanıcının rolüne göre davranır ([Operasyon Ekranı](#operasyon-ekranı)) |
| İzleme | `monitoring/`, `alert-receiver/` | İki uygulama metriklerini ve izlerini ayrı iki OpenTelemetry Collector'a gönderir; metrikleri Prometheus toplar, Grafana panoda gösterir, alarm kuralları tetiklenince Alertmanager bildirimi alert-receiver'a gönderir; izler Jaeger'da bir faturanın yolculuğunu gösterir ([İzleme](#i̇zleme)) |

İki .NET uygulaması Domain / Application / Infrastructure / Api olarak dört katmana ayrılmıştır; katmanlar, port'lar,
akışlar ve tasarım kararları [ARCHITECTURE.md](ARCHITECTURE.md)'de.

Her günün teslim edilen hali bir git tag'idir; README yalnızca uygulamaları ve **bugünün** işini anlatır
(bkz. [Günler](#günler)).

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
| Keycloak | http://localhost:8080 (yönetim konsolu `admin` / `admin`; realm `fatura`) |
| Operasyon Ekranı | http://localhost:5100 |
| Grafana (pano) | http://localhost:3000 (giriş gerekmez; değiştirmek için `admin` / `admin`) |
| Prometheus | http://localhost:9090 (alarmlar: http://localhost:9090/alerts) |
| Alertmanager | http://localhost:9093 |
| Jaeger (izler) | http://localhost:16686 |

Her uygulamanın yalnızca kendi veritabanının bağlantı bilgisi vardır; iki uygulama birbirine yalnızca HTTP ile ulaşır.
Şema EF Core migration ile açılışta oluşur. Docker içinde her uygulama `appsettings.json`'ın üzerine
`appsettings.Docker.json`'ı okur (veritabanı bağlantısı ve karşı uygulamanın adresi oradadır).

---

## ERP Simulator

.NET 10, ASP.NET Core Minimal API, kendi PostgreSQL veritabanı (`erp-db`).

### Endpoint'ler

| Endpoint | Davranış |
|---|---|
| `POST /api/v1/invoices` | Body: `invoiceNumber`, `customerCode`, `amount`, `currency`, `invoiceDate`. Saniyede en fazla 20 istek kabul edilir ([Hız sınırı](#hız-sınırı)); kabul edilen istek seçilen davranışa göre cevap verir (aşağıda) ve cevabı 50–200 ms sonra döner. Eksik/geçersiz alan `400`; tutarda virgülden sonra en fazla iki basamak. |
| `GET /api/v1/invoices/{invoiceNumber}` | `200` + `registered`, `erpReference` (ilk kayıt), `recordCount`, `records[]`, `decision` (`none` / `received` / `approved` / `rejected`), `reason` (yalnızca `rejected`), `decided_at`. Karar ilk kaydın event'lerinden türetilir; event'i hiç gönderilmemiş olsa bile zamanı gelince görünür. Kayıt yoksa `404`. Hata üretmez. |
| `GET /api/v1/invoices?from=…&to=…&page=1&pageSize=100` | `receivedAt`'i `[from, to)` içinde kalan kayıtlar, `(receivedAt, id)` sıralı ve sayfalı: `{page, pageSize, totalCount, items[]}`. `from` ve `to` zorunlu, `from < to`; `pageSize` en çok 500 (üstü `400`). Çift kayıtlar ayrı satırdır. |

```json
POST /api/v1/invoices
{ "invoiceNumber": "INV-2026-0001", "customerCode": "C-001", "amount": 1250.50, "currency": "TRY", "invoiceDate": "2026-09-29" }

202 Accepted
{ "erpReference": "ERP-00000001", "invoiceNumber": "INV-2026-0001", "receivedAt": "2026-09-29T07:00:00+00:00" }
```

### Davranışlar

Geçerli POST için aşağıdaki davranışlardan biri seed'li rastgele seçimle seçilir (aynı seed + aynı istek sırası = aynı
dizi; yeniden başlayınca dizi baştan başlar). Oranlar gerçek yüzdedir:

| Davranış | Varsayılan oran | Cevap | Fatura kaydedilir mi |
|---|---|---|---|
| `Success` | %60 | `202` + ERP referansı | Evet |
| `Busy` | %15 | `429` + `Retry-After` (5–30 sn; saniye ya da HTTP-date, `RetryAfterFormat`) | Hayır |
| `ServerError` | %10 | `500` | Hayır |
| `SaveThenError` | %5 | `500` | Evet |
| `LateResponse` | %10 | 30 sn bekleyip `202` | Evet (önce kayıt, sonra gecikme) |

Çift kayıt varsayılan olarak engellenmez: kaydeden bir davranış seçilirse aynı fatura numarası tekrar kaydedilebilir.
`IdempotentInvoices` açılırsa aynı numara ikinci kez kaydedilmez (aşağıda).

### Hız sınırı

- `POST /api/v1/invoices` için bütün istemcilere ortak tek bir token bucket vardır (`RateLimit:PermitsPerSecond`, 20). Bucket her
  saat saniyesinin başında yeniden dolar; bu yüzden hiçbir saniyede 20'den fazla istek kabul edilmez. Sınırı aşan istek davranış
  seçilmeden `429` + `Retry-After: 1` alır ve kaydedilmez.
- İki 429 logda ayrı yazılır: hız sınırı `Invoice request rejected status=429 reason=rateLimited`, `Busy` davranışı
  `ERP request #… behavior=Busy status=429 reason=busy`.
- Kabul edilen her istek 50–200 ms (rastgele, `Simulator:ProcessingMin/MaxMilliseconds`) işlenir: davranış uygulanır, kayıt ve log
  satırı isteğin geldiği anda yazılır, cevap bu süre dolunca döner. Log satırında `processing=<ms>ms` yazar. Süre seed'li davranış
  dizisini değiştirmez.

### Webhook'lar

Kaydedilen her fatura için iki event planlanır ve faturayla aynı transaction'da `webhook_deliveries` tablosuna yazılır:
önce `invoice.received` (kayıttan 2–10 sn sonra), sonra `invoice.approved` (%80) ya da `invoice.rejected` (%20, `reason`
ile; 2–20 sn sonra). Arka plandaki gönderici zamanı gelen event'i Invoice Service'in `POST /api/v1/erp-webhooks`
adresine gönderir.

- Body: `event_id`, `event_type`, `invoice_number`, `erp_reference`, `occurred_at`, `invoice.rejected`'de `reason`.
- İmza: `X-Erp-Signature` = `HMAC-SHA256(secret, "{X-Erp-Timestamp}.{raw body}")`, küçük harfli hex; timestamp Unix saniye.
- 5 sn içinde 2xx gelmezse aynı event, bir önceki gönderimin başlangıcından 5, 10, 20, 40 ve 80 sn sonra en fazla 5 kez
  daha gönderilir (retry); sonra `Failed`.
- Bilerek çıkarılan sorunlar (oranlar birbirinden bağımsız): çift gönderim (duplicate, %10), sıra karışması (order mix, %15),
  kayıp karar (lost decision, %5), sahte event (fake, %5, yanlış secret), eski event (replay, %5, 10 dk önceki timestamp).
  Fake ve replay 4xx ile reddedilince tekrar gönderilmez.
- Event'ler, planlandıkları isteğin W3C traceparent'ını saklar (`trace_parent`) ve gönderilirken `traceparent` header'ıyla
  taşır: event faturanın trace'inde görünür ([İzler](#i̇zler)).

### Ayarlar

[`appsettings.json`](erp-simulator/src/ErpSimulator.Api/appsettings.json) ve
[`appsettings.Docker.json`](erp-simulator/src/ErpSimulator.Api/appsettings.Docker.json): her değerin yanında ne işe
yaradığı ve neden o değerde olduğu yazılı. Hepsi zorunludur, kodda varsayılan yoktur; eksik ya da kurala aykırıysa
uygulama açılmaz ve nedenini yazar (ör. oranların toplamı 100 değilse gelen toplam). Değişiklikten sonra
`docker compose restart erp-simulator`.

- **`IdempotentInvoices`** (varsayılan `false`): `true` iken aynı fatura numarasıyla gelen istekler sırayla işlenir ve
  numara kayıtlıysa yeniden kaydedilmez: içerik aynıysa mevcut referansla `202` (`behavior=Duplicate`), farklıysa `409`.
  Kontrol ve kayıt, numaradan üretilen PostgreSQL advisory lock'u altında yapılır; unique index eklenmedi, çünkü eski
  çift kayıtlar silinmez ve ayar geri kapatılabilir.
- `Success` 100, hata oranlarının hepsi 0 ise ERP Simulator kusursuz bir ERP gibi davranır.
- `RateLimit:PermitsPerSecond` (20) ve `Simulator:ProcessingMinMilliseconds` / `ProcessingMaxMilliseconds` (50 / 200): hız sınırı ve
  işlem süresi ([Hız sınırı](#hız-sınırı)).

Tek seferlik değişiklik ortam değişkeniyle de yapılabilir (toplam yine 100 olmalı):

```powershell
$env:Simulator__Rates__Success=0; $env:Simulator__Rates__Busy=100; $env:Simulator__Rates__ServerError=0; $env:Simulator__Rates__SaveThenError=0; $env:Simulator__Rates__LateResponse=0; docker compose up -d --force-recreate erp-simulator
```

---

## Invoice Service

.NET 10, ASP.NET Core Minimal API, kendi PostgreSQL veritabanı (`invoice-db`).

Fatura isteğin içinde ERP'ye gönderilmez: fatura ve Outbox kaydı (`erp_outbox`) aynı transaction'da yazılır, istek
hemen `202` döner. Arka plandaki `OutboxWorker` kayıtları ERP Simulator'a gönderir, hataya göre bekleyip tekrar dener
ve sonucu yazar. ERP'nin gönderdiği webhook event'leri imza doğrulandıktan sonra faturaya işlenir. Haberi hiç gelmeyen ya
da başka nedenle ERP'den ayrışan faturalar için mutabakat işi servisin içinde belirli aralıklarla çalışır
([Mutabakat](#mutabakat)). Webhook ve `/health` dışındaki bütün endpoint'ler Keycloak'ın verdiği JWT'yi ister
([Kimlik doğrulama](#kimlik-doğrulama)).

### Veri

| Tablo | İçerik |
|---|---|
| `invoices` | Fatura ve durumu. Numarayı servis üretir (sequence → `FTR-000001`; body'deki `invoiceNumber` yok sayılır). `send_attempt_count` ömür boyu sayaçtır, resend'de sıfırlanmaz. `reject_reason` yalnızca `Reddedildi`'de dolu. `erp_checked_at` / `erp_check_result`: mutabakatın ERP'ye bu faturayı en son ne zaman sorduğu ve cevabı (`Kayıt yok`, `Kayıtlı, karar: …`); yazılması `updated_at`'i değiştirmez |
| `erp_outbox` | Faturanın Outbox kaydı (fatura başına bir satır). `locked_until` / `locked_by` / `claim_token` sahipliği ve eski alımın sonucunun yenisini ezmesini önler. `trace_parent`: faturanın trace'inin W3C traceparent'ı; worker kaydı ilk aldığında yazılır, sonraki denemeler bu trace'i sürdürür, resend değiştirmez ([İzler](#i̇zler)) |
| `erp_webhook_events` | Gelen her geçerli event bir satır (`event_id` birincil anahtar). `delivery_count` tekrar gelişi sayar, `ignore_reason` `Yok Sayıldı`'nın nedenidir (`Geri Götürüyor`, `Kesin Durumda`, `İlerletmiyor`, `Referans Farklı`, `Fatura Yok`) |
| `reconciliation_runs` | Bir mutabakat çalışması: durum (`Çalışıyor` / `Tamamlandı` / `Başarısız`), karşılaştırılan, düzeltilen ve raporlanan sayısı, hata, `started_by` (başlatan operatörün token'daki kullanıcı adı ya da `Zamanlayıcı`; başlatanın kaydedilmesinden önceki çalışmalarda boş), `started_by_sub` (başlatanın token'daki `sub`'ı; zamanlayıcının çalışmasında ve `sub`'ın kaydedilmesinden önceki çalışmalarda boş) |
| `reconciliation_findings` | Çalışmanın bulduğu fark: tür, eylem (`Düzeltildi` / `Raporlandı`), ayrıntı. `Düzeltildi` yalnızca düzeltilen üç türde olabilir (check constraint). Fatura tablosuna foreign key yoktur: ERP'de olup serviste olmayan fatura da raporlanır |
| `operator_actions` | Her müdahale: `operator_name` (token'daki kullanıcı adı), `operator_sub` (token'daki `sub`; `sub`'ın kaydedilmesinden önceki satırlarda boş), `action` (`Yeniden Gönderme`, `Toplu Yeniden Gönderme`, `Mutabakat Başlatma`, `Takibe Alma`, `Takibi Kapatma`), `invoice_number` (mutabakat başlatmada boş), `result` (`Kuyruğa alındı`, `Reddedildi: fatura Bekliyor`, `Başlatıldı: çalışma 12` …), `created_at`. Reddedilen istekler de yazılır; toplu gönderimde fatura başına bir satır |
| `erp_send_pace` | Tek satır: bütün servis kopyalarının paylaştığı bir sonraki boş gönderim sırası (`next_turn_at`). Yalnızca gönderim hızı için kullanılır ([Outbox Worker](#outbox-worker)); EF modelinde yoktur, migration'da SQL ile oluşturulur |
| `invoice_follow_ups` | Takılı bir faturanın elle takibi: `operator_name` / `operator_sub` (açan), `note`, `opened_at`, `closed_at` / `closed_by` / `closed_by_sub` (kapatan; açıkken boş). Fatura başına en fazla bir açık takip (kısmi benzersiz indeks); kapatılanlar geçmiş olarak kalır. Faturanın durumunu değiştirmez |

`invoices.status`: `Bekliyor` → `Gönderildi` ya da `Başarısız`; ERP event'leriyle `Gönderildi` → `İşleme Alındı` →
`Onaylandı` / `Reddedildi` (`Gönderildi`'den doğrudan karar da olur). `Onaylandı` ve `Reddedildi` kesin durumdur.
`Başarısız`: bütün denemeler tükendiğinde ya da ERP Simulator 429 dışında bir 4xx döndüğünde; yalnızca resend onu
yeniden kuyruğa alır. Durum değerleri ve alanlar veritabanında check constraint ile sınırlıdır.

### Endpoint'ler

Webhook ve `/health` dışındaki her endpoint `Authorization: Bearer <token>` ister: okuma izleyici ve operatöre, müdahale yalnızca operatöre,
fatura oluşturma yalnızca sipariş sistemine açıktır ([Kimlik doğrulama](#kimlik-doğrulama)).

| Endpoint | Davranış |
|---|---|
| `POST /api/v1/invoices` | Yalnızca sipariş sistemi. Body: `customerCode`, `amount`, `currency`, `invoiceDate`. Fatura `Bekliyor` durumunda ve `erp_outbox` kaydıyla aynı transaction'da yazılır, `202`. ERP Simulator bu istekte çağrılmaz. Geçersiz body `400` (tutar 0'dan büyük, en fazla 999.999.999.999,99, virgülden sonra en fazla iki basamak), hiçbir şey kaydedilmez. |
| `POST /api/v1/invoices/{invoiceNumber}/resend` | Operatör. Yalnızca `Başarısız` fatura için: Outbox kaydını sıfırlar (`Bekliyor`, 0 deneme, hemen), faturayı `Bekliyor` yapar, `202`. `Başarısız` değilse `409` (`code: invoice_not_failed`, `currentStatus`), yoksa `404` (`code: invoice_not_found`). Aynı anda iki resend gelirse biri `202`, diğeri `409` alır. |
| `POST /api/v1/invoices/resend` | Operatör. Body `{"invoiceNumbers": [...]}`, 1-100 numara (aksi `400`). Her fatura tekli resend'in kurallarıyla, kendi transaction'ında; tekrarlanan numara bir kez. Her zaman `200` + fatura başına sonuç: `queued`, `not_found`, `not_failed` (+ `currentStatus`), `error`. |
| `GET /api/v1/invoices` | Sayfalı liste, en yeni üstte: `status` (geçersizse `400`), `stuck=true` (yalnızca özetin takılı saydığı faturalar; aynı koşul; her faturada `stuck` alanı da bu koşulla gelir), `search` (numaranın bir parçası, büyük/küçük harf fark etmez), `page` (1'den), `pageSize` (1-100, varsayılan 20). Cevap `{items, page, pageSize, totalCount, totalPages}`. |
| `GET /api/v1/invoices/summary` | Her durumdaki fatura sayısı (0 olanlar dahil), toplam, takılı sayısı (`Gönderildi` / `İşleme Alındı`'da `StuckAfterMinutes`'tan uzun kalan) ve ERP'ye gönderim kuyruğu: `queuedCount` (`erp_outbox`'ta `Bekliyor`), `oldestQueuedSeconds` (en eski `Bekliyor` kaydın oluşturulmasından bu yana; kuyruk boşsa `null`), `sentLastMinute` (son 60 sn'de `Tamamlandı` olan). Bütün sayılar tek snapshot'tan okunur. |
| `GET /api/v1/invoices/{invoiceNumber}` | Faturanın servisteki hali (`200`, `rejectReason` dahil) ya da `404`. |
| `GET /api/v1/invoices/{invoiceNumber}/details` | Fatura, `erp_outbox` kaydı, haberleri (geliş sırasıyla), mutabakat bulguları (en yeni üstte; `ERP Karar Vermedi`'den yalnızca en sonuncusu) ve müdahaleler (`operatorActions`, en yeni üstte) tek cevapta; yoksa `404`. |
| `POST /api/v1/reconciliation-runs` | Operatör. Mutabakatı elle başlatır: `202` + `Location` + çalışma (`Çalışıyor`); çalışma arka planda sürer. Başka bir çalışma sürüyorsa (zamanlanmış, elle ya da servisin diğer kopyasında) `409` (`code: reconciliation_running`). |
| `POST /api/v1/invoices/{invoiceNumber}/follow-up` | Operatör. Body `{"note": "..."}` (1-500 karakter, aksi `400`). Yalnızca takılı fatura (aksi `409`, `code: invoice_not_stuck`); açık takip varsa `409` (`code: follow_up_open`, açan ve zamanı); yoksa `404`. `201` + takip. Fatura takılı kalır |
| `POST /api/v1/invoices/{invoiceNumber}/follow-up/close` | Operatör. Açık takibi kapatır (`200`); yoksa `409` (`code: follow_up_not_open`) |
| `GET /api/v1/reconciliation-runs` | Sayfalı çalışma listesi, en yeni üstte (bulgusuz): `page` (1'den), `pageSize` (1-50, varsayılan 20). Cevap `{items, page, pageSize, totalCount, totalPages}`. |
| `GET /api/v1/reconciliation-runs/{id}` | `{ run, findings[] }` ya da `404`. |
| `GET /health` | Token istemez; yalnızca `{"status":"ok"}` döner (servisin ayakta olduğu). Docker ve Kubernetes yoklamaları token taşımaz. |
| `POST /api/v1/erp-webhooks` | ERP webhook event'i; JWT istemez, HMAC ile doğrulanır. İmza header'ları yok/yanlış ya da timestamp 5 dk'dan eski veya ileri: `401`, kaydedilmez. İmza doğru ama body geçersiz: `400`; 64 KB'tan büyük body: `413`. Event 4 sn içinde işlenemezse `503` (ERP tekrar gönderir). Aksi halde `200` + `{eventId, status, repeat}`. |

Müdahaleyi yapan, token'daki kullanıcı adı (`preferred_username`) ve `sub`'dır: `operator_actions`, `invoice_follow_ups` (açan ve
kapatan) ve `reconciliation_runs` (başlatan) ikisini birlikte tutar. Kullanıcı adı Keycloak'ta değiştirilebilir ya da silinen bir
kullanıcının adı ileride başkasına verilebilir; `sub` kullanıcının değişmeyen kimliğidir. Ekran ve API cevapları adı gösterir.
Yeniden gönderme, toplu yeniden gönderme ve mutabakat başlatmanın log satırlarında da `sub=` yazılır. İstekte gönderilen bir ad
(header, query ya da body) okunmaz. Token'da kullanılabilir ad yoksa (boş ya da 100 karakterden uzun) `403`
(`code: operator_name_required` / `operator_name_invalid`) ve hiçbir şey değişmez; token'da `sub` yoksa da `403`
(`code: operator_sub_required`) ve hiçbir şey değişmez.
Kayıt, müdahalenin yaptığı değişiklikle aynı transaction'da yazılır.

### Kimlik doğrulama

Keycloak (`docker-compose.yml`, 26.8.1) açılışta realm'i [`keycloak/fatura-realm.json`](keycloak/fatura-realm.json)'dan kurar;
konsolda elle ayar yapılmaz. Realm zaten varsa dosya okunmaz: dosya değişince `docker compose up -d --force-recreate keycloak`.

| Rol | Kimde | Ne yapabilir |
|---|---|---|
| `fatura-izleyici` | kullanıcı `izleyici` | Okuma endpoint'leri |
| `fatura-operatoru` | kullanıcı `operator` | Okuma ve müdahale: yeniden gönderme, toplu yeniden gönderme, mutabakat başlatma, takibe alma ve kapatma |
| `fatura-olusturucu` | client `siparis-sistemi` (service account) | `POST /api/v1/invoices` |
| — | kullanıcı `rolsuz` | Rol isteyen hiçbir endpoint (yalnızca Swagger gibi geçerli token'ın yettiği adresler); ekranda "Yetkiniz yok" sayfası |

Client'lar: `operasyon-ekrani` (public, secret'sız; yalnızca Authorization Code + PKCE `S256`, şifreyle token vermez; giriş ve çıkıştan
sonra yalnızca `http://localhost:5100/*` adresine döner) ve `siparis-sistemi` (secret'lı, yalnızca client credentials). İkisinin
token'ında da `aud` `fatura-servisi`'dir (audience mapper). Token ömrü 5 dakikadır. Kullanıcı adı ve şifreyle token veren `fatura-test`
client'ı varsayılan kurulumda yoktur: tanımı [`manual-tests/keycloak/`](manual-tests/keycloak/)'tadır, kullanıcı token'ı alan test
script'leri onu çalışan Keycloak'a yönetim API'siyle ekler (`test-client-ekle.ps1`, compose'daki `admin` kullanıcısıyla). Keycloak'ın
verisi container'ın içindedir: container yeniden oluşturulunca client da gider. Test kullanıcılarının şifreleri ve `siparis-sistemi`'nin secret'ı realm dosyasında düz yazılıdır, yalnızca yerel
deneme içindir.

- **Doğrulama** ([`Api/Auth/AuthExtensions.cs`](invoice-service/src/InvoiceService.Api/Auth/AuthExtensions.cs)): servis token'ı kendisi
  doğrular: imza (realm'in yayımladığı anahtarlar, JWKS), issuer (`http://localhost:8080/realms/fatura`), audience (`fatura-servisi`)
  ve süre. Süresi dolan token `Keycloak:ClockSkewSeconds` (30 sn) daha kabul edilir, sonra `401` alır. Anahtarlar ilk istekte discovery
  belgesinden alınır ve bellekte tutulur; her istekte Keycloak'a sorulmaz.
- **Anahtar değişimi:** token'ın imza anahtarı (`kid`) servisin listesinde yoksa servis listeyi Keycloak'tan yeniden okur; yeniden
  başlatmak gerekmez. Bunu tetikleyen ilk istek `401` alır, sonrakiler kabul edilir. Keycloak'ın artık yayımlamadığı bir anahtarla
  imzalı token reddedilir.
- **401 / 403:** token yoksa, imzası bozuksa, süresi dolmuşsa, issuer ya da audience tutmuyorsa `401`; nedeni `WWW-Authenticate`
  header'ındadır. Token geçerli ama rol yetmiyorsa `403`. Roller token'da `realm_access.roles` içindedir; servis her birini ayrı bir
  role claim'ine çevirir (`RealmRoles`).
- **Token istemeyen endpoint'ler** `POST /api/v1/erp-webhooks` (HMAC ile doğrulanır) ve `GET /health`'tir. Swagger (`/swagger`,
  `/openapi/v1.json`) ve `/` geçerli bir token ister, rol istemez. Kuralı yazılmamış yeni bir endpoint de token ister (varsayılan kural).
- **Issuer:** Keycloak'a bilgisayardan `localhost:8080`, container'lardan `keycloak:8080` ile ulaşılır. `KC_HOSTNAME` sayesinde iki
  durumda da token'daki issuer `http://localhost:8080/realms/fatura`'dır; servis anahtarları `keycloak:8080` üzerinden alır
  (`KC_HOSTNAME_BACKCHANNEL_DYNAMIC`).
- **Token almak** (PowerShell; sipariş sistemi için `grant_type = 'client_credentials'`, `client_id = 'siparis-sistemi'` ve realm
  dosyasındaki `client_secret`). Kullanıcı token'ı için test client'ı önce bir kez eklenir: `.\manual-tests\keycloak\test-client-ekle.ps1`.

  ```powershell
  $token = (Invoke-RestMethod -Method Post -Uri http://localhost:8080/realms/fatura/protocol/openid-connect/token -Body @{ grant_type = 'password'; client_id = 'fatura-test'; username = 'operator'; password = 'operator123' }).access_token
  curl.exe http://localhost:5090/api/v1/invoices/summary -H "Authorization: Bearer $token"
  ```

- **Keycloak durursa** çalışan servis anahtarları bellekte tuttuğu için eldeki geçerli token'ları kabul etmeye devam eder; yeni token
  alınamaz, ekran açılamaz. Keycloak kapalıyken yeniden başlayan servis anahtarları alamaz ve geçerli token'ı da reddeder; `401`'in
  açıklaması "issuer is invalid" der, logda ise nedeni söyleyen bir uyarı satırı vardır:
  `warn: InvoiceService.Api.Auth[0] Token rejected: Keycloak cannot be reached at http://keycloak:8080/realms/fatura, so its signing keys are not known: <neden>`.
  Keycloak açılınca token'lar servis yeniden başlatılmadan kabul edilir. Servis Keycloak'ı beklemez: compose'da Keycloak açılmadan
  gelen isteklere `401` döner.
- **Geliştirme modu:** Keycloak `start-dev` ile çalışır (HTTP, container içinde H2); servis Keycloak'ın HTTP adresini kabul eder
  (`RequireHttpsMetadata` kapalı). Container yeniden oluşturulunca realm dosyadan yeniden kurulur, kullanıcılar yeni `sub` alır ve
  Keycloak'ta elle yapılan değişiklik kalmaz. Swagger UI'da token girilecek yer yoktur, tarayıcıda açılmaz.

### Outbox Worker

Worker, zamanı gelmiş ve lock'u olmayan kayıtları tek bir SQL cümlesiyle alır (`FOR UPDATE SKIP LOCKED`), kayda
süreli sahiplik (`locked_until`) ve yeni bir `claim_token` yazar, deneme sayısını gönderimden **önce** artırır. Bir
servis instance'ı aynı anda en fazla 10 gönderim yapar (`MaxConcurrentSends`). Retry kuralları (`RetryPolicy`):

| ERP Simulator cevabı | Ne olur |
|---|---|
| ERP referansı içeren `202` | `Gönderildi` + `erp_reference`, Outbox `Tamamlandı` |
| `429` | `Retry-After` kadar beklenir; jitter eklenmez |
| `500`, 10 sn timeout, ulaşılamama | 2, 4, 8 … sn + 0–1 sn rastgele jitter; planlanan toplam bekleme en fazla 60 sn |
| 429 dışında 4xx | Hemen `Başarısız`, tekrar denenmez |
| 10. deneme de başarısız | Son ERP sorgusunda kayıt bulunursa `Gönderildi`; bulunamaz veya sorgulanamazsa iki kayıt da `Başarısız` |

- **Çift kayıt kontrolü:** fatura daha önce gönderilmeye çalışıldıysa POST'tan önce ERP Simulator'a `GET` ile sorulur:
  varsa referans alınır (POST yok), açıkça `404` ise gönderilir, sorulamazsa gönderilmez ve sonra tekrar denenir.
  Haklar bitince `Başarısız` yapmadan önce bir kez daha sorulur.
- **Sıra:** zamanı gelmiş kayıtlar kuyruğa giriş sırasıyla (`created_at`, sonra `id`) alınır. `next_attempt_at` yalnızca kaydın ne
  zaman alınabileceğini belirler: bekleme süresi dolan tekrar deneme, kendisinden sonra kuyruğa girenlerin önüne geçer.
- **Gönderim hızı:** bütün servis kopyalarının POST'ları saniyede `Outbox:SendsPerSecond`'a (18) göre sıraya konur; ERP Simulator'ın
  sınırı 20'dir, ağ gecikmesi için biraz altında. Her POST, `erp_send_pace` satırını tek bir `UPDATE … RETURNING` ile bir sıra
  ilerletir ve sırası gelene kadar bekler; sıra ve "şimdi" veritabanı saatinden alınır. Sıra bekledikten sonra kaydın hâlâ o alıma
  ait olduğu kontrol edilir, sonra POST yapılır. "ERP'de var mı?" sorguları (`GET`) bu sınıra girmez.
- **Servis öldürülürse** kayıt veritabanında kalır; lock `LockSeconds` (60 sn) sonra dolar ve kayıt yeniden alınabilir.
  Sonuç yalnızca kayıt hâlâ o alımın `claim_token`'ını taşıyorsa yazılır. Son denemesi yarıda kalan kayıt yeniden POST
  edilmez, yalnızca sorulur.
- **Bilinen sınır:** ilk POST ERP'de henüz kaydedilmeden timeout olursa sonraki `GET` `404` dönebilir ve ikinci POST çift
  kayıt oluşturabilir; bunu alıcı tarafta yalnızca ERP Simulator'daki `IdempotentInvoices=true` önler.

### ERP webhook'ları

- **İmza:** `X-Erp-Timestamp` ve `X-Erp-Signature` raw byte'lar üzerinden, sabit zamanlı karşılaştırmayla doğrulanır.
  401'in nedeni yalnızca loga yazılır.
- **Tekrar:** event `INSERT … ON CONFLICT (event_id)` ile bir kez yazılır; sonrakiler `200` alır ve `delivery_count`'u artırır.
- **Uygulama:** fatura satırına `SELECT … FOR UPDATE` ile lock alınır. İleri götüren event uygulanır; `erp_reference`
  farklıysa ya da durumu ilerletmiyorsa event `Yok Sayıldı`, fatura değişmez.
- **Faturadan önce gelen event:** fatura henüz `Gönderildi` değilse `Bekliyor` saklanır; Outbox faturayı `Gönderildi`
  yaptığı transaction'da bekleyenleri geliş sırasıyla işler.
- **Cevap süresi:** cevap en geç 4 sn'de döner. Bu sürede işlenemezse ya da fatura satırının lock'u 2 sn içinde
  alınamazsa `503` dönülür ve ERP event'i tekrar gönderir. `503`'ten sonra iş yine de commit olabilir; o durumda tekrar
  gelen event yalnızca sayılır.

### Mutabakat

`ReconciliationWorker` ayardaki aralıkta çalışır (varsayılan 60 dk; ilk çalışma servis açıldıktan bir aralık sonra); aynı iş
`POST /api/v1/reconciliation-runs` ile elle de başlar. Çalışma son `LookbackHours` saatte oluşan faturaları ve durumu kesinleşmemiş
(`Gönderildi`, `İşleme Alındı`, `Başarısız`) bütün faturaları, yaşına bakmadan, ERP Simulator'ın kayıtlarıyla karşılaştırır. Önce her şeyi okur, sonra yazar: ERP Simulator'a ulaşılamazsa çalışma `Başarısız` olur ve
hiçbir fatura değişmemiştir.

| Bulgu türü | Eylem |
|---|---|
| `Takılı Fatura`: `Gönderildi` / `İşleme Alındı`'da `StuckAfterMinutes`'tan uzun kalmış | ERP'ye kararı sorulur, event'lerle aynı kurallara göre işlenir (**Düzeltildi**) |
| `Başarısız Ama ERP Kayıtlı` | ERP'deki referansla `Gönderildi` olur, karar varsa o da işlenir; `erp_outbox` `Tamamlandı` (**Düzeltildi**) |
| `Tanınmayan Haber`: serviste olmayan faturaya ait, `UnknownEventAfterMinutes`'tan eski bekleyen event | `Yok Sayıldı` (`Fatura Yok`) (**Düzeltildi**) |
| `Serviste Yok`: ERP'de var, serviste hiç yok | Raporlandı |
| `ERP Çift Kayıt`: ERP'de birden fazla kaydı olan fatura | Raporlandı |
| `Alan Farkı`: tutar, para birimi, müşteri kodu ya da `erp_reference` farklı | Raporlandı |
| `ERP Kaydı Yok`: serviste `Gönderildi` ya da sonrası, ERP'de kayıt yok | Raporlandı |
| `ERP Karar Vermedi`: takılı fatura `NoDecisionAfterMinutes`'tan uzun aynı durumda, ERP'ye soruldu ve cevap faturayı ilerletmiyor (`none`, ya da `İşleme Alındı` faturada `received`) | Raporlandı; ERP sessiz kaldıkça her çalışmada yeniden yazılır, karar gelince sonraki çalışma `Takılı Fatura` olarak düzeltir |

- **Aynı anda tek çalışma:** PostgreSQL advisory lock. Zamanlanmış çalışma, elle başlatma ve servisin ikinci kopyası
  aynı kilidi kullanır; kilit başkasındaysa `POST` `409` alır, zamanlanmış tur atlanır. Kilit bağlantıya bağlıdır:
  kopya çökerse veritabanı bırakır.
- **Event'le çakışma:** bir fatura düzeltilirken satırının lock'u (`SELECT … FOR UPDATE`) tutulur; event aynı lock'u
  alır, resend ise aynı satırı güncellediği için lock tutulurken bekler. Lock alındıktan sonra fatura planın gördüğü
  durumda değilse o fatura bırakılır.
- Düzeltilmeyenler hangi tarafın doğru olduğunu bilmeyi gerektirir; bu yüzden yalnızca raporlanır.
- **ERP'ye tek tek sorulan faturalar:** pencerenin dışındaki kesinleşmemiş faturalar ve takılı faturaların kararı. Her sorgu
  loga (`Reconciliation asked the ERP run=… invoice=… answer=…`) ve faturaya (`erp_checked_at`, `erp_check_result`) yazılır;
  çalışma başına özet: `Reconciliation ERP lookups run=… asked=… notFound=… skippedRecentlyNotFound=…`. ERP'nin "yok" dediği
  `Başarısız` fatura `NotFoundRecheckHours` boyunca yeniden sorulmaz; fatura bu arada değişirse (`updated_at` cevaptan
  yeniyse, örn. resend) ilk çalışmada yine sorulur. Eski `Gönderildi` fatura için "yok" `ERP Kaydı Yok` demektir ve her
  çalışmada sorulup raporlanır.
- **Düzeltmesi hata veren fatura:** düzeltmenin transaction'ı geri alınır, fatura değişmez, kalan düzeltmeler sürer. Fatura aynı
  türde, `Raporlandı` olarak ve ayrıntısı "Düzeltme uygulanamadı: <neden>" diye kaydedilir; bir sonraki çalışma yeniden dener.

### Ayarlar

[`appsettings.json`](invoice-service/src/InvoiceService.Api/appsettings.json): her değerin yanında ne işe yaradığı ve
neden o değerde olduğu yazılı. Hepsi zorunludur; eksik ya da kurala aykırıysa servis açılmaz ve nedenini yazar.
Değişiklikten sonra `docker compose up -d --build invoice-service`. Docker'da ERP adresi `appsettings.Docker.json`'dadır.
`ErpWebhooks:Secret`, ERP Simulator'daki `Webhooks:Secret` ile aynı olmalıdır. `Cors:AllowedOrigins` operasyon ekranının
adresidir (`http://localhost:5100`); ekran başka bir adresten açılacaksa buraya eklenir. `Keycloak:BaseUrl`, `Keycloak:Realm` ve
`Keycloak:Audience`: token'ları veren Keycloak ve token'ın taşıması gereken `aud`; Docker'da adres `http://keycloak:8080`'dir.
`Keycloak:ClockSkewSeconds` 30: süresi dolan token'ın kabul edilmeye devam ettiği süre.

Mutabakat ayarları: `IntervalMinutes` 60, `LookbackHours` 24, `StuckAfterMinutes` 2, `UnknownEventAfterMinutes` 60,
`NoDecisionAfterMinutes` 30 (`StuckAfterMinutes`'tan küçük olamaz), `NotFoundRecheckHours` 24. Metrik ayarı:
`Metrics:DatabaseReadSeconds` 15 ([İzleme](#i̇zleme)).
Testler bunları `Reconciliation__…` ortam değişkenleriyle değiştirir (örn. aralığı 1 dk'ya çeker; `docker-compose.yml`'de geçişi var).

### İkinci instance

`docker-compose.yml`'de aynı veritabanını kullanan ikinci bir instance var (`invoice-service-2`, port `5091`, profil
`iki-kopya`); düz `docker compose up` onu başlatmaz:

```bash
docker compose --profile iki-kopya up -d --build invoice-service-2
```

`--build` gerekir: `docker compose up -d --build` profildeki bu servisi derlemez; eski imajla açılan kopya güncel kodu ve ayarları
taşımaz.

---

## Operasyon Ekranı

React + TypeScript (Vite), nginx ile sunulur. Tarayıcı doğrudan Invoice Service'in API'sine gider; adres derlemede
`VITE_API_URL` ile verilir (`docker-compose.yml`, varsayılan `http://localhost:5090`). Keycloak'ın adresi de derlemede
`VITE_KEYCLOAK_URL` ile verilir (varsayılan `http://localhost:8080`). Ekrandaki bütün metinler [`src/tr.ts`](operations-ui/src/tr.ts)'dedir.

| Sayfa | İçerik |
|---|---|
| Özet | Her durumdaki fatura sayısı, takılı fatura sayısı (kart listeyi Takılı süzgeciyle açar), ERP'ye gönderim kuyruğu (kuyrukta bekleyen, en eski bekleme, son 1 dakikada gönderilen), son mutabakat çalışmasının durumu ve bulgu sayıları |
| Fatura Listesi | Durum süzgeci (altı durum ve Takılı; takılı faturada durumun yanında "Takılı · süre" rozeti, takipteyse "Takipte: ad"), numarayla arama, sayfalama (20/50/100). Kolonlar: fatura no, müşteri kodu, tutar, durum, deneme sayısı (toplam), son hata, son güncelleme, detay bağlantısı. Başarısız faturalar seçilip (en fazla 100) toplu yeniden gönderilir; sonuçta kaçının kuyruğa alındığı, kaçının alınamadığı ve nedeni görünür |
| Fatura Detayı | Fatura bilgileri (mutabakatın ERP'ye son sorusu ve cevabı dahil), `erp_outbox` kaydı, gelen bütün haberler, faturanın mutabakat bulguları, müdahaleler (kim, ne, sonuç); Başarısız faturada "Yeniden Gönder"; takılı faturada "Takibe Al" (not ile) / "Takibi Kapat", açık takip ve takip geçmişi |
| Mutabakat | Sayfalı çalışma listesi (20'şer, başlatan dahil), seçili çalışmanın bulguları (Raporlanan ve Düzeltilen ayrı), "Mutabakatı Şimdi Çalıştır" |

- **Giriş:** ekran açılınca giriş yapılmamışsa Keycloak'ın giriş sayfasına gider (client `operasyon-ekrani`, Authorization Code +
  PKCE `S256`, kütüphane `keycloak-js`), girişten sonra açılan sayfaya döner. Giriş bitmeden hiçbir sayfa çizilmez.
- **Token** yalnızca bellekte tutulur, `localStorage`'a ya da `sessionStorage`'a yazılmaz; her istek `Authorization: Bearer` ile gider.
  Sayfa yenilenince token gider; Keycloak'ta oturum açıksa şifre sorulmadan yenisi alınır. Kütüphane giriş yönlendirmesi sırasında
  tek kullanımlık değerleri (state, nonce, PKCE verifier) `localStorage`'a yazar (`kc-callback-*`); tamamlanan girişte siler,
  tamamlanmayanınki bir saat sonra silinir.
- **Yenileme:** her istekten önce token'ın 30 sn'den az ömrü kaldıysa Keycloak'tan yenisi alınır (5 dakikalık token yaklaşık 4,5
  dakikada bir yenilenir); kullanıcı çalıştıkça oturum kesilmez.
- **İşlemsizlik:** kullanıcı 15 dakika hiçbir işlem yapmazsa (tıklama, tuş, kaydırma) oturum kapanır ve giriş sayfası açılır; ekranın
  kendi yenilemeleri işlem sayılmaz. Süre dolmadan bir dakika önce "Uzun süredir işlem yapılmadı; oturumunuz N saniye içinde
  kapanacak." uyarısı ve "Oturumu uzat" butonu çıkar. Süre [`src/config.ts`](operations-ui/src/config.ts)'teki `idleTimeoutMinutes`'tır
  (en az 2), değiştirince ekran yeniden derlenir.
- **Üst çubuk:** sağ üstte token'daki kullanıcı adı ve "Çıkış". Çıkış ekrandaki verileri bellekten siler ve Keycloak'taki oturumu
  kapatır; sonra giriş sayfası açılır, geri tuşu ve yenileme yeniden giriş yapmadan veri göstermez.
- **Rol:** `fatura-operatoru` bütün butonları görür. `fatura-izleyici` verileri görür, müdahale butonlarını görmez (Yeniden Gönder,
  Takibe Al / Takibi Kapat, toplu seçim ve toplu yeniden gönderme, Mutabakatı Şimdi Çalıştır). İkisi de yoksa yalnızca "Yetkiniz yok"
  sayfası açılır. Butonları gizlemek ekranın davranışıdır; aynı kurallar serviste de uygulanır (izleyicinin müdahale isteği `403`).
- **Keycloak'a ulaşılamazsa** ekran açılmaz, "Giriş servisine (Keycloak, http://localhost:8080) ulaşılamıyor. Ekran giriş
  yapılmadan açılmaz; Keycloak çalışınca sayfayı yenileyin." mesajı görünür; tarayıcı Keycloak'ın adresine yönlendirilmez (yönlendirilseydi tarayıcının hata sayfası çıkardı). Token yenilenirken ulaşılamazsa istek gönderilmez ve
  mesaj nedeni Keycloak olarak söyler.
- Her sayfa 10 saniyede bir kendiliğinden yenilenir ve son yenileme zamanını yazar.
- Invoice Service'e ulaşılamazsa sayfa çökmez: "Fatura Servisi'ne ulaşılamıyor" mesajı gösterilir; daha önce veri geldiyse son
  bilinen veri uyarıyla kalır. Servis açılınca bir sonraki yenilemede kendiliğinden toparlanır.
- Reddedilen müdahalede (fatura bu arada başkası tarafından yeniden gönderildiyse, mutabakat zaten çalışıyorsa) servisin `code`
  alanına göre ne olduğunu anlatan Türkçe mesaj gösterilir.

Geliştirme: `npm install --prefix operations-ui`, `npm run dev --prefix operations-ui` (http://localhost:5100);
testler `npm test --prefix operations-ui`.

---

## İzleme

İki uygulama metriklerini (`System.Diagnostics.Metrics`, meter `InvoiceService` ve `ErpSimulator`) ve izlerini OpenTelemetry ile
üretir ve OTLP ile gönderir: metrikleri metrik Collector'ına (`otel-collector-metrics`, 5 saniyede bir,
`OTEL_METRIC_EXPORT_INTERVAL`), izleri iz Collector'ına (`otel-collector`). İkisi ayrı süreç ve ayrı bellek sınırıdır: izlerin yükü
metrikleri etkilemez. Metrik Collector'ı metrikleri Prometheus biçiminde sunar; Prometheus oradan 5 saniyede bir toplar (iz
Collector'ının kendi metriklerini de) ve alarm kurallarını değerlendirir, tetiklenen alarmı Alertmanager webhook ile `alert-receiver`'a
gönderir, alıcı her alarmı bir log satırı olarak yazar. Grafana panoyu Prometheus'tan gösterir. İz Collector'ı izleri örnekleyip
Jaeger'a iletir ([İzler](#i̇zler)). Hepsi `docker compose up -d --build` ile ayağa kalkar; ayarlar, kurallar ve pano
[`monitoring/`](monitoring/) altında dosyadır.

| Dosya | İçerik |
|---|---|
| [`monitoring/otel-collector-metrics/config.yaml`](monitoring/otel-collector-metrics/config.yaml) | Metrik Collector'ı: OTLP alımı, metriklerin Prometheus'a sunulması (`metric_expiration` 15 sn: metrik göndermeyen servisin değerleri 15 sn sonra kalkar), bellek sınırı (`memory_limiter`; container sınırı `docker-compose.yml`'da `mem_limit`); değişiklikten sonra `docker compose restart otel-collector-metrics` |
| [`monitoring/otel-collector/config.yaml`](monitoring/otel-collector/config.yaml) | İz Collector'ı: OTLP alımı, izlerin örneklenip Jaeger'a iletilmesi, bellek sınırı (`memory_limiter`; container sınırı `mem_limit`), kendi metrikleri `:8888`; değişiklikten sonra `docker compose restart otel-collector` |
| [`monitoring/prometheus/prometheus.yml`](monitoring/prometheus/prometheus.yml) | Toplama aralığı (5 sn), hedefler (metrik Collector'ı, `honor_labels` ile `job` servisin adıdır; iz Collector'ının kendi metrikleri, `job=otel-collector`), Alertmanager adresi |
| [`monitoring/prometheus/alert-rules.yml`](monitoring/prometheus/alert-rules.yml) | Yedi alarmın eşiği, süresi ve açıklaması; değişiklikten sonra `docker compose restart prometheus` |
| [`monitoring/alertmanager/alertmanager.yml`](monitoring/alertmanager/alertmanager.yml) | Bütün alarmlar alıcıya; çözülen alarm da bildirilir |
| [`monitoring/grafana/`](monitoring/grafana/) | Veri kaynağı ve pano provisioning'i, pano (`dashboards/fatura-servisi.json`) |

### Metrikler

Adlar Prometheus'ta görünen haliyledir (OpenTelemetry adı noktalıdır: `erp.send.attempts` → `erp_send_attempts_total`).

| Metrik | Tür | Ne ölçer |
|---|---|---|
| `invoices_created_total` | counter | Oluşturulan fatura (fatura ve Outbox kaydı yazıldığında) |
| `erp_send_attempts_total{result}` | counter | ERP'ye gönderim denemeleri; `result`: `accepted`, `busy` (429), `server_error` (5xx), `timeout`, `unreachable`, `already_exists` (sorulunca ERP'de bulundu, POST yapılmadı). Daha önce denenmiş faturada ERP'ye sorulan soru cevapsız kalırsa deneme `timeout` / `unreachable` sayılır |
| `erp_send_duration_seconds` | histogram | ERP'ye fatura POST'unun süresi (sıra beklemesi hariç) |
| `erp_send_pace_wait_seconds` | histogram | Hız sınırında POST'un sırasını beklediği süre |
| `outbox_queued` | gauge | Kuyruktaki fatura (`erp_outbox` `Bekliyor`); özetteki `queuedCount` ile aynı sorgu |
| `outbox_oldest_wait_seconds` | gauge | Kuyruktaki en eski faturanın bekleme süresi; kuyruk boşken 0 |
| `invoices_by_status{status}` | gauge | Durum başına fatura |
| `invoices_stuck` | gauge | Takılı fatura (özetteki tanım) |
| `erp_webhooks_received_total{result}` | counter | Gelen haberler; `result`: `processed` (İşlendi), `waiting` (Bekliyor), `ignored` (Yok Sayıldı), `401`, `503`. Tekrar gelen haber ilk gelişinde sayılır |
| `reconciliation_runs_total{status}` | counter | Biten mutabakat çalışmaları; `status`: `Tamamlandı`, `Başarısız` |
| `reconciliation_duration_seconds` | histogram | Mutabakat çalışmalarının süresi |
| `reconciliation_findings_total{type}` | counter | Mutabakat bulguları, türe göre |
| `reconciliation_last_completed_time_seconds` | gauge | En son `Tamamlandı` çalışmanın bitiş zamanı (Unix saniye); hiç tamamlanan yoksa değer yok |
| `erp_simulator_invoice_requests_total{behavior}` | counter | Simülatörde davranış seçilen fatura istekleri, davranışa göre |
| `erp_simulator_rate_limited_total` | counter | Simülatörde hız sınırından 429 alan istekler (davranış seçilmeden) |

- **Veritabanından okunanlar** (`outbox_*`, `invoices_by_status`, `invoices_stuck`, `reconciliation_last_completed_time_seconds`):
  Invoice Service bunları okur (özet API'sinin tek snapshot sorgusu ve son tamamlanan çalışma), bellekte tutar ve sonraki okumadan
  önce `Metrics:DatabaseReadSeconds` (15) saniye bekler; her gönderim son okumayı taşır, veritabanına gitmez. Her okuma loga yazılır:
  `Metrics read from the database queued=… oldestQueuedSeconds=… stuck=… lastCompletedRun=…`. Okuma hata verirse bu metriklerin
  değeri olmaz (eski değer gösterilmez).
- Sayaçların her etiket değeri açılışta 0 ile başlar (örn. `result="401"` hiç 401 gelmeden de vardır).

### Pano

Grafana'da tek pano: **Fatura Servisi** (ana sayfa; 5 saniyede bir yenilenir). Saniyedeki gönderim (son 1 dakikanın ortalaması),
gönderim sonuçlarının dağılımı, ERP cevap süresi p50 / p95, kuyruk uzunluğu ve en eski bekleme, takılı fatura, haber sonuçları,
son başarılı mutabakattan beri geçen süre, mutabakat çalışmaları, çalışma süresi ve bulgular. İki servis kopyası çalışırken
veritabanından okunan değerler `max()`, sayaçlar `sum()` ile alınır.

### Alarmlar

| Alarm | Koşul ([`alert-rules.yml`](monitoring/prometheus/alert-rules.yml)) |
|---|---|
| `KuyruktaUzunBekleyenFatura` | Kuyruktaki en eski faturanın bekleme süresi 5 dakika boyunca 15 dakikanın üzerinde |
| `TakiliFaturaCok` | Takılı fatura 10 dakika boyunca 50'nin üzerinde |
| `ErpyeUlasilamiyor` | Son 5 dakikadaki gönderim denemelerinin yarısından fazlası `timeout` ya da `unreachable` |
| `BasariliMutabakatYok` | En son `Tamamlandı` çalışma 2 saatten eski |
| `CokSayida401` | Son 5 dakikada 20'den fazla haber 401 |
| `MetrikToplanamiyor` | Invoice Service'in ya da ERP Simulator'ın metrikleri Prometheus'ta 1 dakika boyunca yok; servis başına ayrı alarm. Servis durduktan sonra bildirim yaklaşık 1,5-2 dakikada gelir (metrik Collector'ının 15 sn'si, değerlendirme aralığı, `for` ve Alertmanager'ın beklemesi). İz Collector'ının reddi bunu tetiklemez |
| `CollectorIzReddediyor` | İz Collector'ı son 5 dakikada gelen span'leri reddetti (bellek sınırı, `otelcol_receiver_refused_spans_total`); yalnız ret sayacına bakar, servisin durmasıyla karışmaz. Son retten 4-5 dakika sonra çözülür |

Her alarmın açıklamasında sorun ve operasyon ekibinin ilk yapacağı iş yazar. Bildirimler alıcının logunda:
`docker compose logs -f alert-receiver` (`Alert status=firing alertname=… summary="…" description="…"`; koşul kalkınca
`status=resolved`).

### İzler

HTTP istekleri, HttpClient çağrıları ve veritabanı sorguları (Npgsql) kendiliğinden izlenir; aşağıdaki span'leri uygulamalar
kendisi açar. Bir faturanın yolculuğu, worker kaydı kuyruktan ilk aldığında başlayan tek trace'tir; oluşturma isteği kendi
trace'idir:

| Adım | Span |
|---|---|
| Faturanın oluşturulması (ayrı trace) | `POST /api/v1/invoices/` (Invoice Service), `invoice.number` |
| Kuyrukta bekleme (faturanın trace'inin ilk span'i) | `outbox.queue_wait`: başlangıcı faturanın oluşturulma anı, bitişi kaydın kuyruktan ilk alınması (geriye tarihli), `outbox.queue_wait_seconds` |
| Worker'ın kaydı alması | `outbox.claimed` (her denemede; `outbox.queue_wait_seconds`: kaydın zamanı geldikten alınmasına kadar) |
| Her gönderim denemesi | `outbox.attempt`: `outbox.attempt` (deneme numarası), `outbox.outcome` (`Sent` / `Retry` / `Failed`), `outbox.wait_seconds` (sonraki denemeye kadar), `outbox.check`, `erp.http_status`; başarısız deneme hata olarak işaretlenir |
| Hız sınırında bekleme | `erp.pace_wait` |
| Simülatördeki işlem | `POST /api/v1/invoices/` (ERP Simulator), `simulator.outcome` (seçilen davranış) |
| Simülatörden gelen haberler | `webhook.send` (ERP Simulator) → `POST /api/v1/erp-webhooks` (Invoice Service), `erp_event.status`; haber uygulanınca span'e olay eklenir: `erp event stored` ya da fatura Gönderildi olunca deneme span'inde `erp event applied-after-send` |
| Mutabakatın düzeltmesi | `reconciliation.fix`: `reconciliation.finding_type`, `reconciliation.fix` (düzeltme türü), `invoice.status` (faturanın yeni durumu) |
| Operatörün yeniden gönderimi | `invoice.resend`: `operator.action` (`Resend` / `BulkResend`); ardından denemeler 1'den başlar |

- **Bağlam:** zamanın koptuğu iki yerde W3C traceparent saklanır: `erp_outbox.trace_parent` (kaydın ilk alındığı denemede, ERP
  çağrılmadan önce) ve simülatörün `webhook_deliveries.trace_parent` (event planlanırken). Haber isteğinde `traceparent` header'ıyla
  gider.
- **Faturanın izini bulmak:** Jaeger'da (http://localhost:16686) Service `invoice-service`, Tags `invoice.number=FTR-000123`; iki trace
  çıkar: faturanın trace'i (`outbox.queue_wait` ile başlar) ve oluşturma isteği (`POST /api/v1/invoices/`).
- **Loglar:** iki uygulamanın her log satırının sonunda o anki `trace_id=` yazar (span dışında `trace_id=-`); bir faturanın iki
  servisteki satırları `docker compose logs invoice-service erp-simulator | Select-String trace_id=<trace_id>` ile bulunur
  (`trace_id`, faturanın `ERP send start` satırından alınır; `Invoice queued` satırı oluşturma isteğinin trace_id'sini taşır).
- **Worker'ların sorguları kaydedilmez:** iki uygulamada sampler, hiçbir istek ya da adım altında olmayan veritabanı / HTTP
  çağrısını (worker'ların kuyruk sorguları, metrik okumaları, zamanlanmış mutabakatın sorguları) kaydetmez; bu izler Collector'a
  gelmez. Elle başlatılan mutabakatın sorguları, başlatan isteğin izinde kaydedilir.
- **Örnekleme:** uygulamalar kaydettikleri izleri gönderir; hangilerinin saklanacağına Collector karar verir (tail sampling,
  [`config.yaml`](monitoring/otel-collector/config.yaml)). Karar, trace'in ilk span'i geldikten 2 dakika sonra bütün yolculuğa
  birlikte uygulanır; faturanın trace'inde bu süre kaydın kuyruktan ilk alınmasıyla başlar:

  | Trace | Saklanır mı |
  |---|---|
  | 1. ya da 2. denemede gönderilen fatura | `sampling_percentage` kadarı (%10) |
  | En az 3 kez denenen fatura | Hepsi |
  | Gönderilmemiş fatura (Başarısız, ya da karar anında henüz gönderilmemiş) | Hepsi |
  | Oluşturma isteği (gönderim içermez) | Hepsi |
  | Fatura numarası taşımayan (faturayla ilgisi olmayan istekler) | Hiçbiri |

  Karar süresi yetmezse henüz gönderilmemiş fatura saklanır: sorunlu fatura kaybolmaz, sorunsuz oranı %10'un üstüne çıkar. Karar
  verildikten sonra gelen span'ler (geç haberler, sonraki denemeler, mutabakatın düzeltmesi) aynı karara uyar. Kaç trace'in
  saklanıp atıldığı iz Collector'ının kendi metriklerinde (Prometheus'ta `job="otel-collector"`):
  `otelcol_processor_tail_sampling_global_count_traces_sampled_total{sampled="true"|"false"}`.
- **Saklama:** Jaeger izleri bellekte tutar; varsayılan ayarıyla en fazla 100.000 trace, sınır dolunca en eskileri silinir. Jaeger
  yeniden başlayınca bütün izler gider. Collector kararını bekleyen izleri bellekte tutar; Collector yeniden başlarsa onlar da gider.
- **İz Collector'ının belleği:** `memory_limiter` heap'i 1 saniyede bir ölçer; 1.200 MiB'ı (`limit_mib` 1600 − `spike_limit_mib` 400)
  geçince gelen veriyi reddeder, altına inince yeniden kabul eder. Container'ın sınırı 2.048 MiB'tır (`mem_limit`); `limit_mib`
  bunun altında tutulur ki Collector öldürülmeden önce veri reddetsin. Biri değişirse diğeri de değişmelidir. Ret
  `CollectorIzReddediyor` alarmını tetikler; metrikler ayrı Collector'da olduğu için etkilenmez.

---

## Testler

| Ne | Komut |
|---|---|
| Unit ve entegrasyon testleri | `dotnet test erp-simulator`, `dotnet test invoice-service/InvoiceService.slnx` (entegrasyon testleri için Docker gerekir), `npm test --prefix operations-ui` |
| Yük testi | `docker compose run --rm k6` ([aşağıda](#yük-testi)) |
| Gün 19 kontrol listesi (ekranda işlemsizlik süresi, kısaltılmış süreyle; rol ve audience kontrolü kaldırılınca kırılan testler; bütün testlerin 10 kez koşulması) | [`manual-tests/gun19/`](manual-tests/gun19/) |
| Gün 18 kontrol listesi (kayıtta kullanıcı adıyla `sub`; `/health` token'sız; varsayılan kurulumda `fatura-test` yok; süresi dolmuş token 30 sn sonra `401`; izleyicinin token'ıyla müdahale `403`; çıkıştan önce ve sonra Keycloak oturumu; Keycloak durdurma). Ekran maddeleri tarayıcıda yapılır | [`manual-tests/gun18/`](manual-tests/gun18/) |
| Gün 17 kontrol listesi (compose sonrası realm; endpoint × durum tablosu; operator_actions'ta token'daki ad; token ömründen uzun yük testi; webhook HMAC; Keycloak durdurma) ve audience / issuer kontrolü | [`manual-tests/gun17/`](manual-tests/gun17/) |
| Gün 16 kontrol listesi (bellek sınırı denemesinde metriklerin sürekliliği ve alarmlar; 2 dakikalık karar süresiyle 10 dakikalık yük testi ve metrik Collector'ının maliyeti; servis ve veritabanı durdurma; alarm geçmişi; iz Collector'ını durdurma ve iki kopya; metrik Collector'ını durdurma) | [`manual-tests/gun16/`](manual-tests/gun16/) |
| Gün 15 kontrol listesi (10 dakikalık yük testinde saklanan sorunsuz oranı, sorunlu ve oluşturma izleri, Collector belleği; boşta bekleyen trace; kuyrukta 30 dakikadan uzun beklemiş faturanın izi; bellek sınırı denemesi) | [`manual-tests/gun15/`](manual-tests/gun15/) |
| Gün 14 kontrol listesi (Collector'ın bellek sınırı; 10 dakikalık yük testinde Collector belleği, reddedilen span'ler, zaman içinde saklanan sorunsuz oranı, sorunlu faturaların izleri) | [`manual-tests/gun14/`](manual-tests/gun14/) |
| Gün 13 kontrol listesi (yük altında örnekleme ve Collector belleği, boşta worker izleri, uzun süren faturanın izi, mutabakat ve yeniden gönderim izde, repeat_interval) | [`manual-tests/gun13/`](manual-tests/gun13/) |
| Gün 12 kontrol listesi (pano ve alarmlar, Jaeger'daki izler, log satırlarında trace_id) ve izlemenin maliyeti | [`manual-tests/gun12/`](manual-tests/gun12/) |
| Gün 11 kontrol listesi (pano, alarmlar, metrikler) | [`manual-tests/gun11/`](manual-tests/gun11/README.md) |
| Gün 10 ölçümleri (yük testi önce/sonra, iki kopya) | [`manual-tests/gun10/`](manual-tests/gun10/) |
| Gün 9 kontrol listesi | [`manual-tests/gun9/`](manual-tests/gun9/) |
| Gün 8 kontrol listesi | [`manual-tests/gun8/`](manual-tests/gun8/) |
| Gün 7 kontrol listesi (script'li maddeler) ve ekrandan yapılan maddelerin adımları | [`manual-tests/gun7/`](manual-tests/gun7/README.md) |
| Gün 6 kontrol listesi | [`manual-tests/gun6/`](manual-tests/gun6/README.md) |
| Gün 5 kontrol listesi (2-9. maddeler; 1. madde Gün 3 ve Gün 4 listeleridir), adım ve ek test | [`manual-tests/gun5/`](manual-tests/gun5/) |
| Gün 4 kontrol listesi, adım ve ek testleri | [`manual-tests/gun4/`](manual-tests/gun4/) |
| Gün 3 kontrol listesi | [`manual-tests/gun3/`](manual-tests/gun3/README.md) |
| ERP Simulator | [`manual-tests/gun1/`](manual-tests/gun1/README.md) |
| Veritabanı / loglar | `.\manual-tests\gun1\db.ps1`, `.\manual-tests\gun1\loglar.ps1` (ERP Simulator), `.\manual-tests\gun2\db.ps1` (Invoice Service) |
| ERP Simulator bash script'leri | `./scripts/erp-simulator-checklist.sh`, `./scripts/erp-simulator-distribution.sh <adet>` |

`manual-tests/gun2/` script'leri Gün 2'deki eşzamanlı gönderimi test eder ve [gun-2](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-2)
tag'inde çalıştırılmalıdır. Gün 1-16 script'leri token göndermez: API'ye istek atanlar o günlerin tag'lerinde çalıştırılmalıdır.

### Entegrasyon testleri

[`invoice-service/tests/InvoiceService.IntegrationTests`](invoice-service/tests/InvoiceService.IntegrationTests). Docker dışında bir şey
gerekmez: Testcontainers bir PostgreSQL 17 container'ı açar, migration'ları bir şablon veritabanına uygular, her test şablondan kendi
veritabanını alır (testler birbirinin verisini görmez). ERP yerine testin içinde açılan küçük bir HTTP sunucusu vardır. Beklemeler koşula
bağlıdır (`Eventually.WaitUntilAsync`); sabit süreli bekleme yalnızca token'ın süresi ve toleransı içindir.

Kimlik doğrulama testleri ayrıca gerçek bir Keycloak açar (Testcontainers, `quay.io/keycloak/keycloak:26.8.1`); realm
[`keycloak/fatura-realm.json`](keycloak/fatura-realm.json)'dan kurulur, kullanıcı token'ları için `fatura-test` client'ı
`manual-tests/keycloak/`'taki tanımdan yönetim API'siyle eklenir (ekranın client'ı PKCE ile tarayıcı istediği için kullanılmaz; iki
client'ın token'ında roller, audience ve issuer aynıdır). Servis test içinde bütün HTTP hattıyla açılır
(`WebApplicationFactory`) ve gerçek token'larla istek alır. Bir farkı sınayan test (kısa token ömrü, audience'sız ya da `sub`'sız
token, ikinci realm, anahtar değişimi) client'ın ya da realm'in bir kopyasını açar; Keycloak'ı kapatan test kendi container'ını kullanır.

- **Komutlar:** `dotnet test invoice-service/InvoiceService.slnx` birim ve entegrasyon testlerini birlikte çalıştırır;
  `dotnet test invoice-service/tests/InvoiceService.IntegrationTests` yalnızca entegrasyon testlerini. Birim testler bu projeye
  eklenmedi, hızlı kalır.
- **GitHub Actions:** [`.github/workflows/invoice-service-tests.yml`](.github/workflows/invoice-service-tests.yml) her push'ta
  `dotnet test invoice-service/InvoiceService.slnx` çalıştırır.

| Senaryo | Test |
|---|---|
| 1. İki worker aynı kaydı almaz | `OutboxClaimTests.Two_workers_taking_at_the_same_moment_never_take_the_same_entry` |
| 2. Süresi dolan worker'ın geç sonucu ezmez | `OutboxClaimTests.A_late_result_of_the_old_worker_...` (2 test) |
| 3. Gönderildi'den önce gelen haber kaybolmaz | `WebhookEventTests.An_event_that_comes_before_the_invoice_is_Gonderildi_...` |
| 4. Aynı haber 10 kez aynı anda, bir kez işlenir | `WebhookEventTests.The_same_event_arriving_ten_times_at_once_is_processed_once` |
| 5. Mutabakat iki kez çalışmaz, çöken kopyanın kilidi düşer | `ReconciliationLockTests` (2 test) |
| 6. Mutabakat düzeltmesi ve haber birbirini bozmaz | `ReconciliationFixRaceTests.A_fix_and_an_event_...` |
| 7. Başarısız faturada düzeltme ve resend aynı anda | `ReconciliationFixRaceTests.A_fix_of_a_Failed_invoice_and_a_resend_...` |
| 8. İki kopya, 100 sıra: ardışık sıralar ve gönderimlerin başladığı anlar aralıktan kısa değil; sistem boşta kaldıktan sonra da | `SendPaceTests` (2 test: sıra `now()` iken ve bir dakika geride iken) |
| 9. Zamanı gelmiş kayıtlar kuyruğa giriş sırasıyla alınır | `OutboxClaimTests.Entries_whose_time_has_come_are_taken_in_the_order_they_entered_the_queue_...` |
| 10. Sürekli hata alan faturalar yeni faturanın gönderimini durdurmaz | `OutboxClaimTests.Invoices_that_keep_failing_do_not_hold_back_a_new_invoice` |
| 11. İlk deneme başlattığı trace'i kayda yazar, resend trace'i değiştirmez | `OutboxClaimTests.The_first_attempt_stores_the_trace_it_started_and_a_resend_keeps_it` |
| 12. Rol kuralları: okuma, müdahale ve fatura oluşturmanın her endpoint'i, webhook ve `/health`; izleyici, operatör, rolsüz ve sipariş sistemi token'larıyla | `RoleRuleTests` (14 endpoint × 4 token = 56 durum) |
| 13. Geçersiz token'lar `401` (nedeniyle): imzası bozulmuş, süresi ve 30 sn toleransı dolmuş, başka realm'den, audience'ı tutmayan | `InvalidTokenTests` (4 test) |
| 14. Keycloak imza anahtarını değiştirince yeni anahtarlı token kabul, kaldırılan anahtarlı token ret; servis yeniden başlatılmaz | `KeyRotationTests` |
| 15. Müdahale kaydında token'daki ad ve `sub`; `sub`'sız token'la müdahale `403`, kayıt yok | `InterventionRecordTests` (2 test) |
| 16. Keycloak kapalıyken açılan servis token'ı reddeder ve logda uyarı satırı yazar; Keycloak açılınca yeniden başlatılmadan kabul eder | `KeycloakDownTests` (Keycloak aynı portta yeni container olarak açılır: Testcontainers durdurulan Keycloak container'ını yeniden hazır hale getirirken takılıyor; yeni container yeni anahtar ürettiği için kabul yeni token'la sınanır) |

Özet sayısının yük altındaki ölçümü: [`manual-tests/gun9/1-ozet-yuk-altinda.ps1`](manual-tests/gun9/1-ozet-yuk-altinda.ps1)
(yük testi sürerken çalıştırılır).

### Yük testi

[`load-test/invoices.js`](load-test/invoices.js) Invoice Service'e dakikada 3000 fatura (saniyede 50) gönderir, 5 dakika boyunca,
toplam 15.000. k6 kurulmaz: compose'daki `k6` servisi (profil `yuk-testi`, sabit sürümlü imaj) aynı ağın içinden çalışır.

```bash
docker compose run --rm k6
```

İstekler sipariş sisteminin token'ıyla gider (client credentials); her VU kendi token'ını bitmeden 30 sn önce yeniler. Token ömrü
5 dakika olduğu için yenilemeyi görmek için süre uzatılır (`DURATION=7m`).

Ortam değişkenleri: `BASE_URLS` (virgülle birden fazla adres; istekler sırayla dağıtılır), `RATE`, `DURATION`, `RUN_ID` (faturaların
müşteri kodu; verilmezse `LOAD-<zaman>`). Sonuç ekrana ve `load-test/results/<RUN_ID>.json`'a yazılır (istek sayısı,
`POST /api/v1/invoices` p50 / p95 / p99, VU, alınan token ve 401 alan istek sayısı; token istekleri süreye ve istek sayısına
girmez); p95 200 ms'yi geçerse k6 hata koduyla biter. Kuyruk boşaldıktan sonraki sonuç tablosu:
`.\manual-tests\gun8\6-yuk-olcum.ps1 -RunId <RUN_ID>`.

Manuel deneme: Swagger UI veya `.http` dosyaları
([ERP Simulator](erp-simulator/src/ErpSimulator.Api/ErpSimulator.Api.http), [Invoice Service](invoice-service/src/InvoiceService.Api/InvoiceService.Api.http);
Invoice Service'inki önce operatörün (test client'ı eklendikten sonra) ve sipariş sisteminin token'ını alır, Swagger UI token istediği için tarayıcıda açılmaz);
loglar için `docker compose logs -f erp-simulator` / `docker compose logs -f invoice-service`.
Script'ler engellenirse önce `Set-ExecutionPolicy -Scope Process Bypass`.

---

## Gün 19 — Kimlik Doğrulamanın Otomatik Testleri

Bugünün işi: Gün 18'in ardından kalan düzeltmeler ve kimlik doğrulamanın gerçek Keycloak'la çalışan otomatik testleri.

- **Düzeltmeler:** ekranda 15 dakika işlem yapılmazsa oturum kapanır, bir dakika önce uyarı ve "Oturumu uzat" çıkar; süre ekranın
  ayarında (`src/config.ts`), ekranın kendi yenilemeleri işlem sayılmaz ([Operasyon Ekranı](#operasyon-ekranı)). Token'da `sub` yoksa
  müdahale `403` alır. Keycloak'a ulaşamadan açılan servis token'ı reddettiğinde logda nedeni söyleyen bir uyarı satırı vardır
  ([Kimlik doğrulama](#kimlik-doğrulama)).
- **Keycloak'lı entegrasyon testleri:** testler Keycloak'ı Testcontainers ile kendileri açar, realm'i repodaki dosyadan kurar; mevcut
  entegrasyon testleriyle birlikte her push'ta GitHub Actions'ta çalışır ([Entegrasyon testleri](#entegrasyon-testleri), senaryo 12-16).
  Anahtar değişimi testi için servisin kaldırılan imza anahtarını reddetmesi sağlandı (kütüphanenin "last known good" davranışı kapalı).

Kontrol listesi ([`manual-tests/gun19/`](manual-tests/gun19/); 1. madde tarayıcıda yapılır):

| # | Madde | Sonuç |
|---|---|---|
| 1 | Ekranda işlemsizlik | Süre ayarda (`idleTimeoutMinutes`) 2 dakikaya indirilip ekran derlendi (`1-ekran-sure.ps1 -Hazirla`), operatörle giriş yapıldı, sayfaya uzatma dışında dokunulmadı. 1. dakikada uyarı çıktı ("oturumunuz 47 saniye içinde kapanacak"); "Oturumu uzat" ile süre baştan başladı; uzatmadan 1 dakika sonra uyarı yeniden çıktı, 2 dakika sonra giriş sayfası açıldı. Keycloak'ta operatörün oturumu girişte 1, sonunda 0. Ekranın 10 saniyelik yenilemeleri süreyi sıfırlamadı |
| 2 | Beş senaryonun testleri | 5 senaryo, 64 test (`RoleRuleTests` 56, `InvalidTokenTests` 4, `KeyRotationTests` 1, `InterventionRecordTests` 2, `KeycloakDownTests` 1); hepsi geçti |
| 3 | Rol ve audience kontrolü kaldırılınca | Her satır ayrı koşu (`3-mutasyon.ps1`, `AuthExtensions.cs`): okuma kuralı `RequireRole(...)` → `RequireAuthenticatedUser()`: 12 test kırıldı (6 okuma endpoint'i × rolsüz ve sipariş sistemi; "Expected: 403, Actual: 200/404"); müdahale kuralı: 15 (5 endpoint × izleyici, rolsüz, sipariş sistemi; "Expected: 403", Actual endpoint'e göre 404, 409, 200 ya da 202); fatura oluşturma kuralı: 3 (izleyici, operatör, rolsüz; "Expected: 403, Actual: 202"); `ValidateAudience = false`: 1 (`A_token_without_the_services_audience_gets_401`, "Expected: Unauthorized, Actual: OK"). Her koşuda diğer testler geçti, kod geri alındı |
| 4 | Bütün testler 10 kez | Fatura Servisi (birim 406 + entegrasyon 80), ERP Simülatörü (124) ve ekran (27), tur başına 637 test; 10 turun hepsinde hepsi geçti. Entegrasyon testleri tur başına 2 dk 6 sn – 2 dk 23 sn (`4-on-tekrar.ps1`) |
| 5 | Süre ve GitHub Actions | 80 entegrasyon testi 2 dk 20 sn ([Actions çalışması](https://github.com/metinkaryagdi/Staj_Tasks/actions/runs/40317650239)) |

`1-ekran-sure.ps1 -Hazirla` yığını bu güne özel volume'lerle açar, `config.ts`'teki süreyi yalnızca derleme için değiştirip geri alır;
`-Oturum once|sonra` operatörün Keycloak oturumlarını yönetim API'sinden okur, `-Hazirla -Dakika 15` ekranı ayardaki süreyle geri derler.
`3-mutasyon.ps1` dört mutasyonu sırayla koşar (~10 dk), `4-on-tekrar.ps1` üç takımı 10 kez (~35 dk).

### Bilinen sınırlar

- **Anahtar değişiminden sonraki ilk istek:** servis yeni anahtarı ilk gördüğü istekte öğrenir; o istek `401` alır, sonrakiler kabul
  edilir. Bu, her servis kopyasında bir kez olur.
- **Servisin önceden okuduğu anahtar:** Keycloak'ta önce yeni anahtar eklenip servis onu öğrendikten sonra eski anahtar kaldırılırsa,
  eski anahtar servisin listesinde durduğu için liste kendiliğinden yenilenene kadar kabul edilir (denemede kaldırıldıktan sonraki
  3 saniye boyunca kabul edildi). Test, anahtarın servis yeni anahtarı görmeden kaldırıldığı sırayla yazılmıştır.

---

## Günler

| Tag | Gün | O günün hali |
|---|---|---|
| `gun-1` | ERP Simulator | [tree/gun-1](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-1) |
| `gun-2` | Invoice Service'in ilk sürümü | [tree/gun-2](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-2) |
| `gun-3` | Güvenli Gönderim | [tree/gun-3](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-3) |
| `gun-4` | ERP'den Gelen Haberler | [tree/gun-4](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-4) |
| `gun-5` | Mutabakat | [tree/gun-5](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-5) |
| `gun-6` | Operasyon Ekranı | [tree/gun-6](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-6) |
| `gun-7` | Operasyon ekranındaki eksikler | [tree/gun-7](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-7) |
| `gun-8` | Yoğun Dönem | [tree/gun-8](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-8) |
| `gun-9` | Gerçek Veritabanıyla Otomatik Testler | [tree/gun-9](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-9) |
| `gun-10` | Tekrar Denenen Faturaların Sırası | [tree/gun-10](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-10) |
| `gun-11` | Metrikler, Pano ve Alarm | [tree/gun-11](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-11) |
| `gun-12` | Bir Faturanın Yolculuğunu İzlemek | [tree/gun-12](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-12) |
| `gun-13` | İzlerin Örneklenmesi | [tree/gun-13](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-13) |
| `gun-14` | Collector'ı Yüke Karşı Korumak | [tree/gun-14](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-14) |
| `gun-15` | İzlemeyi Toparlamak | [tree/gun-15](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-15) |
| `gun-16` | Metrikleri İz Yükünden Ayırmak | [tree/gun-16](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-16) |
| `gun-17` | Kimlik Doğrulama, Keycloak ve API | [tree/gun-17](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-17) |
| `gun-18` | Operasyon Ekranına Giriş | [tree/gun-18](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-18) |
| `gun-19` | Kimlik Doğrulamanın Otomatik Testleri | [tree/gun-19](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-19) |
