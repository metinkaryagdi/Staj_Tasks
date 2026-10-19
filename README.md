# Staj_Tasks

Fatura entegrasyonu üzerine staj projesi: Invoice Service, ona hata üreterek cevap veren ve faturanın sonucunu imzalı
webhook'larla bildiren ERP Simulator, ve sistemi izleyip müdahale etmek için operasyon ekranı.

| Uygulama | Klasör | Ne yapar |
|---|---|---|
| ERP Simulator | `erp-simulator/` | Faturaları kabul eden ERP'yi taklit eder; saniyede sınırlı sayıda isteği kabul eder; her isteğe seed'li rastgele bir hata davranışı uygular; kaydettiği faturalar için Invoice Service'e imzalı webhook gönderir (bilerek sorunlu) |
| Invoice Service | `invoice-service/` | Faturayı ve Outbox kaydını birlikte kaydeder; arka planda ERP'ye gönderir; ERP'den gelen webhook event'lerini doğrulayıp faturaya işler; belirli aralıklarla kendi kayıtlarını ERP'ninkiyle karşılaştırır (mutabakat), düzeltebildiğini düzeltir, düzeltemediğini raporlar |
| Operasyon Ekranı | `operations-ui/` | Faturaların ve mutabakatın durumunu veritabanına bakmadan gösterir; Başarısız faturaları tek tek ya da toplu yeniden kuyruğa alır, mutabakatı başlatır. Yalnızca Invoice Service'in API'siyle konuşur |
| İzleme | `monitoring/`, `alert-receiver/` | İki uygulama metriklerini ve izlerini OpenTelemetry Collector'a gönderir; metrikleri Prometheus toplar, Grafana panoda gösterir, alarm kuralları tetiklenince Alertmanager bildirimi alert-receiver'a gönderir; izler Jaeger'da bir faturanın yolculuğunu gösterir ([İzleme](#i̇zleme)) |

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
([Mutabakat](#mutabakat)).

### Veri

| Tablo | İçerik |
|---|---|
| `invoices` | Fatura ve durumu. Numarayı servis üretir (sequence → `FTR-000001`; body'deki `invoiceNumber` yok sayılır). `send_attempt_count` ömür boyu sayaçtır, resend'de sıfırlanmaz. `reject_reason` yalnızca `Reddedildi`'de dolu. `erp_checked_at` / `erp_check_result`: mutabakatın ERP'ye bu faturayı en son ne zaman sorduğu ve cevabı (`Kayıt yok`, `Kayıtlı, karar: …`); yazılması `updated_at`'i değiştirmez |
| `erp_outbox` | Faturanın Outbox kaydı (fatura başına bir satır). `locked_until` / `locked_by` / `claim_token` sahipliği ve eski alımın sonucunun yenisini ezmesini önler. `trace_parent`: faturanın trace'inin W3C traceparent'ı; worker kaydı ilk aldığında yazılır, sonraki denemeler bu trace'i sürdürür, resend değiştirmez ([İzler](#i̇zler)) |
| `erp_webhook_events` | Gelen her geçerli event bir satır (`event_id` birincil anahtar). `delivery_count` tekrar gelişi sayar, `ignore_reason` `Yok Sayıldı`'nın nedenidir (`Geri Götürüyor`, `Kesin Durumda`, `İlerletmiyor`, `Referans Farklı`, `Fatura Yok`) |
| `reconciliation_runs` | Bir mutabakat çalışması: durum (`Çalışıyor` / `Tamamlandı` / `Başarısız`), karşılaştırılan, düzeltilen ve raporlanan sayısı, hata, `started_by` (başlatan kişi ya da `Zamanlayıcı`; başlatanın kaydedilmesinden önceki çalışmalarda boş) |
| `reconciliation_findings` | Çalışmanın bulduğu fark: tür, eylem (`Düzeltildi` / `Raporlandı`), ayrıntı. `Düzeltildi` yalnızca düzeltilen üç türde olabilir (check constraint). Fatura tablosuna foreign key yoktur: ERP'de olup serviste olmayan fatura da raporlanır |
| `operator_actions` | Ekrandan yapılan her müdahale: `operator_name`, `action` (`Yeniden Gönderme`, `Toplu Yeniden Gönderme`, `Mutabakat Başlatma`, `Takibe Alma`, `Takibi Kapatma`), `invoice_number` (mutabakat başlatmada boş), `result` (`Kuyruğa alındı`, `Reddedildi: fatura Bekliyor`, `Başlatıldı: çalışma 12` …), `created_at`. Reddedilen istekler de yazılır; toplu gönderimde fatura başına bir satır |
| `erp_send_pace` | Tek satır: bütün servis kopyalarının paylaştığı bir sonraki boş gönderim sırası (`next_turn_at`). Yalnızca gönderim hızı için kullanılır ([Outbox Worker](#outbox-worker)); EF modelinde yoktur, migration'da SQL ile oluşturulur |
| `invoice_follow_ups` | Takılı bir faturanın elle takibi: `operator_name`, `note`, `opened_at`, `closed_at` / `closed_by` (açıkken boş). Fatura başına en fazla bir açık takip (kısmi benzersiz indeks); kapatılanlar geçmiş olarak kalır. Faturanın durumunu değiştirmez |

`invoices.status`: `Bekliyor` → `Gönderildi` ya da `Başarısız`; ERP event'leriyle `Gönderildi` → `İşleme Alındı` →
`Onaylandı` / `Reddedildi` (`Gönderildi`'den doğrudan karar da olur). `Onaylandı` ve `Reddedildi` kesin durumdur.
`Başarısız`: bütün denemeler tükendiğinde ya da ERP Simulator 429 dışında bir 4xx döndüğünde; yalnızca resend onu
yeniden kuyruğa alır. Durum değerleri ve alanlar veritabanında check constraint ile sınırlıdır.

### Endpoint'ler

| Endpoint | Davranış |
|---|---|
| `POST /api/v1/invoices` | Body: `customerCode`, `amount`, `currency`, `invoiceDate`. Fatura `Bekliyor` durumunda ve `erp_outbox` kaydıyla aynı transaction'da yazılır, `202`. ERP Simulator bu istekte çağrılmaz. Geçersiz body `400` (tutar 0'dan büyük, en fazla 999.999.999.999,99, virgülden sonra en fazla iki basamak), hiçbir şey kaydedilmez. |
| `POST /api/v1/invoices/{invoiceNumber}/resend` | `X-Operator-Name` gerekir (aşağıya bakın). Yalnızca `Başarısız` fatura için: Outbox kaydını sıfırlar (`Bekliyor`, 0 deneme, hemen), faturayı `Bekliyor` yapar, `202`. `Başarısız` değilse `409` (`code: invoice_not_failed`, `currentStatus`), yoksa `404` (`code: invoice_not_found`). Aynı anda iki resend gelirse biri `202`, diğeri `409` alır. |
| `POST /api/v1/invoices/resend` | `X-Operator-Name` gerekir. Body `{"invoiceNumbers": [...]}`, 1-100 numara (aksi `400`). Her fatura tekli resend'in kurallarıyla, kendi transaction'ında; tekrarlanan numara bir kez. Her zaman `200` + fatura başına sonuç: `queued`, `not_found`, `not_failed` (+ `currentStatus`), `error`. |
| `GET /api/v1/invoices` | Sayfalı liste, en yeni üstte: `status` (geçersizse `400`), `stuck=true` (yalnızca özetin takılı saydığı faturalar; aynı koşul; her faturada `stuck` alanı da bu koşulla gelir), `search` (numaranın bir parçası, büyük/küçük harf fark etmez), `page` (1'den), `pageSize` (1-100, varsayılan 20). Cevap `{items, page, pageSize, totalCount, totalPages}`. |
| `GET /api/v1/invoices/summary` | Her durumdaki fatura sayısı (0 olanlar dahil), toplam, takılı sayısı (`Gönderildi` / `İşleme Alındı`'da `StuckAfterMinutes`'tan uzun kalan) ve ERP'ye gönderim kuyruğu: `queuedCount` (`erp_outbox`'ta `Bekliyor`), `oldestQueuedSeconds` (en eski `Bekliyor` kaydın oluşturulmasından bu yana; kuyruk boşsa `null`), `sentLastMinute` (son 60 sn'de `Tamamlandı` olan). Bütün sayılar tek snapshot'tan okunur. |
| `GET /api/v1/invoices/{invoiceNumber}` | Faturanın servisteki hali (`200`, `rejectReason` dahil) ya da `404`. |
| `GET /api/v1/invoices/{invoiceNumber}/details` | Fatura, `erp_outbox` kaydı, haberleri (geliş sırasıyla), mutabakat bulguları (en yeni üstte; `ERP Karar Vermedi`'den yalnızca en sonuncusu) ve müdahaleler (`operatorActions`, en yeni üstte) tek cevapta; yoksa `404`. |
| `POST /api/v1/reconciliation-runs` | `X-Operator-Name` gerekir. Mutabakatı elle başlatır: `202` + `Location` + çalışma (`Çalışıyor`); çalışma arka planda sürer. Başka bir çalışma sürüyorsa (zamanlanmış, elle ya da servisin diğer kopyasında) `409` (`code: reconciliation_running`). |
| `POST /api/v1/invoices/{invoiceNumber}/follow-up` | `X-Operator-Name` gerekir. Body `{"note": "..."}` (1-500 karakter, aksi `400`). Yalnızca takılı fatura (aksi `409`, `code: invoice_not_stuck`); açık takip varsa `409` (`code: follow_up_open`, açan ve zamanı); yoksa `404`. `201` + takip. Fatura takılı kalır |
| `POST /api/v1/invoices/{invoiceNumber}/follow-up/close` | `X-Operator-Name` gerekir. Açık takibi kapatır (`200`); yoksa `409` (`code: follow_up_not_open`) |
| `GET /api/v1/reconciliation-runs` | Sayfalı çalışma listesi, en yeni üstte (bulgusuz): `page` (1'den), `pageSize` (1-50, varsayılan 20). Cevap `{items, page, pageSize, totalCount, totalPages}`. |
| `GET /api/v1/reconciliation-runs/{id}` | `{ run, findings[] }` ya da `404`. |
| `POST /api/v1/erp-webhooks` | ERP webhook event'i. İmza header'ları yok/yanlış ya da timestamp 5 dk'dan eski veya ileri: `401`, kaydedilmez. İmza doğru ama body geçersiz: `400`; 64 KB'tan büyük body: `413`. Event 4 sn içinde işlenemezse `503` (ERP tekrar gönderir). Aksi halde `200` + `{eventId, status, repeat}`. |

`X-Operator-Name`: müdahaleyi yapanın adı (kimlik doğrulama değildir, yalnızca kayıt için). Üç müdahale isteğinde zorunludur;
yoksa ya da boşsa `400` (`code: operator_name_required`), 100 karakterden uzunsa `400` (`code: operator_name_invalid`) ve hiçbir
şey değişmez. Tarayıcı header'da Latin-1 dışı karakter gönderemediği için ad yüzde kodlu (`encodeURIComponent`) gönderilir, servis
çözer; düz ASCII ad olduğu gibi de gönderilebilir. Kayıt, müdahalenin yaptığı değişiklikle aynı transaction'da yazılır.

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
adresidir (`http://localhost:5100`); ekran başka bir adresten açılacaksa buraya eklenir.

Mutabakat ayarları: `IntervalMinutes` 60, `LookbackHours` 24, `StuckAfterMinutes` 2, `UnknownEventAfterMinutes` 60,
`NoDecisionAfterMinutes` 30 (`StuckAfterMinutes`'tan küçük olamaz), `NotFoundRecheckHours` 24. Metrik ayarı:
`Metrics:DatabaseReadSeconds` 15 ([İzleme](#i̇zleme)).
Testler bunları `Reconciliation__…` ortam değişkenleriyle değiştirir (örn. aralığı 1 dk'ya çeker; `docker-compose.yml`'de geçişi var).

### İkinci instance

`docker-compose.yml`'de aynı veritabanını kullanan ikinci bir instance var (`invoice-service-2`, port `5091`, profil
`iki-kopya`); düz `docker compose up` onu başlatmaz:

```bash
docker compose --profile iki-kopya up -d invoice-service-2
```

---

## Operasyon Ekranı

React + TypeScript (Vite), nginx ile sunulur. Tarayıcı doğrudan Invoice Service'in API'sine gider; adres derlemede
`VITE_API_URL` ile verilir (`docker-compose.yml`, varsayılan `http://localhost:5090`). Ekrandaki bütün metinler
[`src/tr.ts`](operations-ui/src/tr.ts)'dedir.

| Sayfa | İçerik |
|---|---|
| Özet | Her durumdaki fatura sayısı, takılı fatura sayısı (kart listeyi Takılı süzgeciyle açar), ERP'ye gönderim kuyruğu (kuyrukta bekleyen, en eski bekleme, son 1 dakikada gönderilen), son mutabakat çalışmasının durumu ve bulgu sayıları |
| Fatura Listesi | Durum süzgeci (altı durum ve Takılı; takılı faturada durumun yanında "Takılı · süre" rozeti, takipteyse "Takipte: ad"), numarayla arama, sayfalama (20/50/100). Kolonlar: fatura no, müşteri kodu, tutar, durum, deneme sayısı (toplam), son hata, son güncelleme, detay bağlantısı. Başarısız faturalar seçilip (en fazla 100) toplu yeniden gönderilir; sonuçta kaçının kuyruğa alındığı, kaçının alınamadığı ve nedeni görünür |
| Fatura Detayı | Fatura bilgileri (mutabakatın ERP'ye son sorusu ve cevabı dahil), `erp_outbox` kaydı, gelen bütün haberler, faturanın mutabakat bulguları, müdahaleler (kim, ne, sonuç); Başarısız faturada "Yeniden Gönder"; takılı faturada "Takibe Al" (not ile) / "Takibi Kapat", açık takip ve takip geçmişi |
| Mutabakat | Sayfalı çalışma listesi (20'şer, başlatan dahil), seçili çalışmanın bulguları (Raporlanan ve Düzeltilen ayrı), "Mutabakatı Şimdi Çalıştır" |

- İlk açılışta kullanıcının adı sorulur ve tarayıcıda (`localStorage`) saklanır; sayfa yenilenince yeniden sorulmaz. Ad üst
  çubukta görünür, "Değiştir" ile yeniden sorulur. Ekranın her müdahalesi bu adı `X-Operator-Name` ile gönderir.
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
üretir ve OTLP ile OpenTelemetry Collector'a gönderir (metrikler 5 saniyede bir, `OTEL_METRIC_EXPORT_INTERVAL`). Collector metrikleri
Prometheus biçiminde sunar; Prometheus oradan 5 saniyede bir toplar ve alarm kurallarını değerlendirir, tetiklenen alarmı Alertmanager
webhook ile `alert-receiver`'a gönderir, alıcı her alarmı bir log satırı olarak yazar. Grafana panoyu Prometheus'tan gösterir.
Collector izleri Jaeger'a iletir ([İzler](#i̇zler)). Hepsi `docker compose up -d --build` ile ayağa kalkar; ayarlar, kurallar ve pano
[`monitoring/`](monitoring/) altında dosyadır.

| Dosya | İçerik |
|---|---|
| [`monitoring/otel-collector/config.yaml`](monitoring/otel-collector/config.yaml) | OTLP alımı; metriklerin Prometheus'a sunulması (`metric_expiration` 15 sn: metrik göndermeyen servisin değerleri 15 sn sonra kalkar), izlerin Jaeger'a iletilmesi; Collector'ın bellek sınırı (`memory_limiter`; container sınırı `docker-compose.yml`'da `mem_limit`); değişiklikten sonra `docker compose restart otel-collector` |
| [`monitoring/prometheus/prometheus.yml`](monitoring/prometheus/prometheus.yml) | Toplama aralığı (5 sn), hedef (Collector; `honor_labels` ile `job` servisin adıdır), Alertmanager adresi |
| [`monitoring/prometheus/alert-rules.yml`](monitoring/prometheus/alert-rules.yml) | Altı alarmın eşiği, süresi ve açıklaması; değişiklikten sonra `docker compose restart prometheus` |
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
| `MetrikToplanamiyor` | Invoice Service'in ya da ERP Simulator'ın metrikleri Prometheus'ta 1 dakika boyunca yok; servis başına ayrı alarm. Servis durduktan sonra bildirim yaklaşık 1,5-2 dakikada gelir (Collector'ın 15 sn'si, değerlendirme aralığı, `for` ve Alertmanager'ın beklemesi) |

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
  [`config.yaml`](monitoring/otel-collector/config.yaml)). Karar, trace'in ilk span'i geldikten 30 dakika sonra bütün yolculuğa
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
  saklanıp atıldığı Collector'ın kendi metriklerinde (`otel-collector:8888/metrics`, compose ağında):
  `otelcol_processor_tail_sampling_global_count_traces_sampled_total{sampled="true"|"false"}`.
- **Saklama:** Jaeger izleri bellekte tutar; varsayılan ayarıyla en fazla 100.000 trace, sınır dolunca en eskileri silinir. Jaeger
  yeniden başlayınca bütün izler gider. Collector kararını bekleyen izleri bellekte tutar; Collector yeniden başlarsa onlar da gider.
- **Collector'ın belleği:** `memory_limiter` heap'i 1 saniyede bir ölçer; 1.200 MiB'ı (`limit_mib` 1600 − `spike_limit_mib` 400)
  geçince gelen veriyi reddeder, altına inince yeniden kabul eder. Container'ın sınırı 2.048 MiB'tır (`mem_limit`); `limit_mib`
  bunun altında tutulur ki Collector öldürülmeden önce veri reddetsin. Biri değişirse diğeri de değişmelidir.

---

## Testler

| Ne | Komut |
|---|---|
| Unit ve entegrasyon testleri | `dotnet test erp-simulator`, `dotnet test invoice-service/InvoiceService.slnx` (entegrasyon testleri için Docker gerekir), `npm test --prefix operations-ui` |
| Yük testi | `docker compose run --rm k6` ([aşağıda](#yük-testi)) |
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
tag'inde çalıştırılmalıdır.

### Entegrasyon testleri

[`invoice-service/tests/InvoiceService.IntegrationTests`](invoice-service/tests/InvoiceService.IntegrationTests). Docker dışında bir şey
gerekmez: Testcontainers bir PostgreSQL 17 container'ı açar, migration'ları bir şablon veritabanına uygular, her test şablondan kendi
veritabanını alır (testler birbirinin verisini görmez). ERP yerine testin içinde açılan küçük bir HTTP sunucusu vardır. Beklemeler koşula
bağlıdır (`Eventually.WaitUntilAsync`); sabit süreli bekleme yoktur.

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

Özet sayısının yük altındaki ölçümü: [`manual-tests/gun9/1-ozet-yuk-altinda.ps1`](manual-tests/gun9/1-ozet-yuk-altinda.ps1)
(yük testi sürerken çalıştırılır).

### Yük testi

[`load-test/invoices.js`](load-test/invoices.js) Invoice Service'e dakikada 3000 fatura (saniyede 50) gönderir, 5 dakika boyunca,
toplam 15.000. k6 kurulmaz: compose'daki `k6` servisi (profil `yuk-testi`, sabit sürümlü imaj) aynı ağın içinden çalışır.

```bash
docker compose run --rm k6
```

Ortam değişkenleri: `BASE_URLS` (virgülle birden fazla adres; istekler sırayla dağıtılır), `RATE`, `DURATION`, `RUN_ID` (faturaların
müşteri kodu; verilmezse `LOAD-<zaman>`). Sonuç ekrana ve `load-test/results/<RUN_ID>.json`'a yazılır (istek sayısı,
`POST /api/v1/invoices` p50 / p95 / p99); p95 200 ms'yi geçerse k6 hata koduyla biter. Kuyruk boşaldıktan sonraki sonuç tablosu:
`.\manual-tests\gun8\6-yuk-olcum.ps1 -RunId <RUN_ID>`.

Manuel deneme: Swagger UI veya `.http` dosyaları
([ERP Simulator](erp-simulator/src/ErpSimulator.Api/ErpSimulator.Api.http), [Invoice Service](invoice-service/src/InvoiceService.Api/InvoiceService.Api.http));
loglar için `docker compose logs -f erp-simulator` / `docker compose logs -f invoice-service`.
Script'ler engellenirse önce `Set-ExecutionPolicy -Scope Process Bypass`.

---

## Gün 15 — İzlemeyi Toparlamak

Bugünün işi: faturanın izi worker kaydı kuyruktan ilk aldığında başlıyor, worker'ların sorguları hiç kaydedilmiyor ve
Collector'ın bellek sınırı bilerek düşürülerek denendi.

- **İzin başlangıcı:** ilk span kuyrukta bekleme (`outbox.queue_wait`, faturanın oluşturulma anından geriye tarihli);
  oluşturma isteği kendi izidir ve fatura numarasıyla bulunur ([İzler](#i̇zler)).
- **Worker sorguları:** iki uygulamada sampler, hiçbir istek altında olmayan veritabanı / HTTP çağrısını kaydetmez; toplu kayıt
  almanın span'i ve link'i kalktı.
- **Uzun yük testi** (saniyede 50 fatura, 10 dakika, simülatörün varsayılan oranları; kuyruk 1 sa 18 dk'da boşaldı): saklanan
  sorunsuz fatura oranı ilk 30 dakikada %9,9, sonrasında %9,4; 3.010 sorunlu faturanın hiçbirinin izi kaybolmadı. Collector'da
  bellekte en çok 41.704 trace, en yüksek bellek 1.068 MiB; sistem boştayken bellekte 0 trace.
- **Başarısız faturalar** (ayrı kısa koşu, simülatör yalnız 500 döndürür): 30 faturanın 30'u Başarısız oldu, hepsinin izi saklandı.
- **Bellek sınırı denemesi** (`limit_mib` 400, `spike_limit_mib` 100): Collector 857.490 span'i ve 21.734 metrik noktasını
  reddetti; faturaların hepsi gönderildi, aynı faturanın gönderim süresi normal sınırlı (1600 / 400) koşudakinden ortanca 1,4 sn farklı. Sınır
  1600 / 400'e döndü.

Kontrol listesi: [`manual-tests/gun15/`](manual-tests/gun15/). `1-uzun-yuk.ps1` yük testini simülatörün ayarına dokunmadan çalıştırır,
Collector'ın belleğini ve kendi metriklerini kaydeder, sonunda boşta bir mutabakat çalışmasından sonra bellekteki trace'leri okur;
ardından `2-sayim.ps1` (her fatura Jaeger'da aranır, fatura izi ve oluşturma izi ayrı sayılır) ve `3-ekran.ps1` (Jaeger görüntüleri)
çalışır. `4-bellek-denemesi.ps1 -LimitMib 400 -SpikeMib 100` sınırı yalnız deneme süresince düşürür, uygulamaların OpenTelemetry
tanılama logunu açar ve bitince ikisini de geri alır. `5-basarisiz.ps1` simülatörü yalnız 500 döndürecek şekilde açar, Başarısız
olan faturaların izlerini sayar ve simülatörü varsayılan ayarlarına döndürür.

### Bilinen sınırlar

- **Collector** kararını bekleyen izleri bellekte tutar; yeniden başlarsa bekleyen izler (sorunlu faturalarınki dahil) kaybolur.
  Ölçüme göre (simülatörün varsayılan oranlarında işleme hızı saniyede 6,4) ilk dolan sınır `num_traces`'tir (100.000): 30 dakika
  boyunca saniyede yaklaşık 49 fatura gelirse; dolunca en eski trace'ler karar verilmeden atılır.
- **Bellek sınırı** aşılınca reddedilen span'ler ve metrik noktaları kaybolur: uygulamalar yeniden göndermez ve bunu konsol loguna
  yazmaz (yalnız OpenTelemetry'nin tanılama loguna, açıksa). Metrikler de reddedildiği için servisler çalışırken
  `MetrikToplanamiyor` alarmı tetiklenebilir (denemede servislerin metrikleri 36-38 dakika görünmedi).
- **Collector'ın belleğini** çoğunlukla fatura izleri doldurur (karar süresi boyunca bütün span'leriyle); sayıları faturaların
  kuyruktan alınma hızına bağlıdır. Fatura izi başına heap varsayılan oranlarda ölçüldü; buna göre birikmiş bir kuyruk saniyede
  yaklaşık 10 faturadan hızlı boşalırsa heap bellek sınırına ulaşır.
- **Karar süresi** (30 dakika) kuyruk beklemesini kapsayacak biçimde seçilmişti; iz artık kuyruktan çıkışta başladığı için bu gerekçe
  yoktur, değer değiştirilmedi.
- **Oluşturma isteğinin izi** her fatura için saklanır: uzun testte 30.000 fatura için 35.596 trace saklandı. Jaeger en fazla
  100.000 trace tutar ve en eskileri siler; bu oranla yaklaşık 84.000 faturada dolar (oluşturma izleri olmadan yaklaşık 536.000).
  Jaeger yeniden başlayınca bütün izler gider.
- **İlk alış yarıda kalırsa:** iz kayda yazılamadan deneme biterse (kayıt bu arada başka bir worker'a geçtiyse ya da iz
  yazılmadan bir hata çıktıysa) kuyruk adımı yine gönderilir ve faturanın ikinci bir izi oluşur. Servis deneme sırasında durursa
  kuyruk adımı hiç gönderilmez: iz kayda yazılmışsa sonraki denemeler kökü olmayan bir izde sürer, yazılmamışsa sonraki alış yeni
  bir iz başlatır ve kuyruk adımı ilk denemeyi ve kilit süresini de içerir.
- **Gönderim kuyrukları:** uygulamanın ve Collector'ın gönderim kuyrukları dolarsa span'ler düşebilir; bunu gösteren metrik ya da
  alarm yoktur.
- **Mutabakat ve operatör işlemleri** bir fatura için yazdıkları log satırlarında faturanın trace_id'sini taşımaz: zamanlanmış
  mutabakatta `trace_id=-`, elle başlatılan mutabakatta ve operatör işlemlerinde isteğin trace_id'si yazar.
- **Loglar** container'da tutulur; container yeniden oluşturulunca eski satırlar gider.
- **Eski kayıtlar:** bu sürümden önce kuyruğa girmiş kayıtlar, `trace_parent`'larındaki oluşturma isteğinin izini sürdürür.
- **Aynı fatura numarası** farklı veritabanlarında yeniden üretildiği için Jaeger'da birden fazla trace'te çıkabilir; arama zaman
  aralığıyla daraltılmalıdır.
- **MetrikToplanamiyor** servis bazındadır: iki kopyadan yalnız biri durursa tetiklenmez. Collector durursa iki servisin alarmı
  birlikte tetiklenir.
- **Alertmanager** hangi alarmı bildirdiğini 15 dakikada bir diske yazar; düzgün kapanmadan yeniden başlarsa eski kaydı yükler ve aynı
  alarm yeniden tetiklendiğinde bildirimi `repeat_interval` (1 saat) dolana kadar göndermez. Alarm Prometheus'ta ve panoda görünür.

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
