# Staj_Tasks

Fatura entegrasyonu üzerine staj projesi: Invoice Service, ona hata üreterek cevap veren ve faturanın sonucunu imzalı
webhook'larla bildiren ERP Simulator, ve sistemi izleyip müdahale etmek için operasyon ekranı.

| Uygulama | Klasör | Ne yapar |
|---|---|---|
| ERP Simulator | `erp-simulator/` | Faturaları kabul eden ERP'yi taklit eder; her isteğe seed'li rastgele bir hata davranışı uygular; kaydettiği faturalar için Invoice Service'e imzalı webhook gönderir (bilerek sorunlu) |
| Invoice Service | `invoice-service/` | Faturayı ve Outbox kaydını birlikte kaydeder; arka planda ERP'ye gönderir; ERP'den gelen webhook event'lerini doğrulayıp faturaya işler; belirli aralıklarla kendi kayıtlarını ERP'ninkiyle karşılaştırır (mutabakat), düzeltebildiğini düzeltir, düzeltemediğini raporlar |
| Operasyon Ekranı | `operations-ui/` | Faturaların ve mutabakatın durumunu veritabanına bakmadan gösterir; Başarısız faturaları tek tek ya da toplu yeniden kuyruğa alır, mutabakatı başlatır. Yalnızca Invoice Service'in API'siyle konuşur |

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

Her uygulamanın yalnızca kendi veritabanının bağlantı bilgisi vardır; iki uygulama birbirine yalnızca HTTP ile ulaşır.
Şema EF Core migration ile açılışta oluşur. Docker içinde her uygulama `appsettings.json`'ın üzerine
`appsettings.Docker.json`'ı okur (veritabanı bağlantısı ve karşı uygulamanın adresi oradadır).

---

## ERP Simulator

.NET 10, ASP.NET Core Minimal API, kendi PostgreSQL veritabanı (`erp-db`).

### Endpoint'ler

| Endpoint | Davranış |
|---|---|
| `POST /api/v1/invoices` | Body: `invoiceNumber`, `customerCode`, `amount`, `currency`, `invoiceDate`. Seçilen davranışa göre cevap verir (aşağıda). Eksik/geçersiz alan `400`; tutarda virgülden sonra en fazla iki basamak. |
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
| `erp_outbox` | Faturanın Outbox kaydı (fatura başına bir satır). `locked_until` / `locked_by` / `claim_token` sahipliği ve eski alımın sonucunun yenisini ezmesini önler |
| `erp_webhook_events` | Gelen her geçerli event bir satır (`event_id` birincil anahtar). `delivery_count` tekrar gelişi sayar, `ignore_reason` `Yok Sayıldı`'nın nedenidir (`Geri Götürüyor`, `Kesin Durumda`, `İlerletmiyor`, `Referans Farklı`, `Fatura Yok`) |
| `reconciliation_runs` | Bir mutabakat çalışması: durum (`Çalışıyor` / `Tamamlandı` / `Başarısız`), karşılaştırılan, düzeltilen ve raporlanan sayısı, hata, `started_by` (başlatan kişi ya da `Zamanlayıcı`; başlatanın kaydedilmesinden önceki çalışmalarda boş) |
| `reconciliation_findings` | Çalışmanın bulduğu fark: tür, eylem (`Düzeltildi` / `Raporlandı`), ayrıntı. `Düzeltildi` yalnızca düzeltilen üç türde olabilir (check constraint). Fatura tablosuna foreign key yoktur: ERP'de olup serviste olmayan fatura da raporlanır |
| `operator_actions` | Ekrandan yapılan her müdahale: `operator_name`, `action` (`Yeniden Gönderme`, `Toplu Yeniden Gönderme`, `Mutabakat Başlatma`), `invoice_number` (mutabakat başlatmada boş), `result` (`Kuyruğa alındı`, `Reddedildi: fatura Bekliyor`, `Başlatıldı: çalışma 12` …), `created_at`. Reddedilen istekler de yazılır; toplu gönderimde fatura başına bir satır |

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
| `GET /api/v1/invoices` | Sayfalı liste, en yeni üstte: `status` (geçersizse `400`), `stuck=true` (yalnızca özetin takılı saydığı faturalar; aynı koşul), `search` (numaranın bir parçası, büyük/küçük harf fark etmez), `page` (1'den), `pageSize` (1-100, varsayılan 20). Cevap `{items, page, pageSize, totalCount, totalPages}`. |
| `GET /api/v1/invoices/summary` | Her durumdaki fatura sayısı (0 olanlar dahil), toplam ve takılı sayısı (`Gönderildi` / `İşleme Alındı`'da `StuckAfterMinutes`'tan uzun kalan). |
| `GET /api/v1/invoices/{invoiceNumber}` | Faturanın servisteki hali (`200`, `rejectReason` dahil) ya da `404`. |
| `GET /api/v1/invoices/{invoiceNumber}/details` | Fatura, `erp_outbox` kaydı, haberleri (geliş sırasıyla), mutabakat bulguları (en yeni üstte; `ERP Karar Vermedi`'den yalnızca en sonuncusu) ve müdahaleler (`operatorActions`, en yeni üstte) tek cevapta; yoksa `404`. |
| `POST /api/v1/reconciliation-runs` | `X-Operator-Name` gerekir. Mutabakatı elle başlatır: `202` + `Location` + çalışma (`Çalışıyor`); çalışma arka planda sürer. Başka bir çalışma sürüyorsa (zamanlanmış, elle ya da servisin diğer kopyasında) `409` (`code: reconciliation_running`). |
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
servis instance'ı aynı anda en fazla 10 gönderim yapar. Retry kuralları (`RetryPolicy`):

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
`NoDecisionAfterMinutes` 30 (`StuckAfterMinutes`'tan küçük olamaz), `NotFoundRecheckHours` 24.
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
| Özet | Her durumdaki fatura sayısı, takılı fatura sayısı (kart listeyi Takılı süzgeciyle açar), son mutabakat çalışmasının durumu ve bulgu sayıları |
| Fatura Listesi | Durum süzgeci (altı durum ve Takılı), numarayla arama, sayfalama (20/50/100). Kolonlar: fatura no, müşteri kodu, tutar, durum, deneme sayısı (toplam), son hata, son güncelleme, detay bağlantısı. Başarısız faturalar seçilip (en fazla 100) toplu yeniden gönderilir; sonuçta kaçının kuyruğa alındığı, kaçının alınamadığı ve nedeni görünür |
| Fatura Detayı | Fatura bilgileri (mutabakatın ERP'ye son sorusu ve cevabı dahil), `erp_outbox` kaydı, gelen bütün haberler, faturanın mutabakat bulguları, müdahaleler (kim, ne, sonuç); Başarısız faturada "Yeniden Gönder" |
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

## Testler

| Ne | Komut |
|---|---|
| Unit testler | `dotnet test erp-simulator`, `dotnet test invoice-service`, `npm test --prefix operations-ui` |
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

Manuel deneme: Swagger UI veya `.http` dosyaları
([ERP Simulator](erp-simulator/src/ErpSimulator.Api/ErpSimulator.Api.http), [Invoice Service](invoice-service/src/InvoiceService.Api/InvoiceService.Api.http));
loglar için `docker compose logs -f erp-simulator` / `docker compose logs -f invoice-service`.
Script'ler engellenirse önce `Set-ExecutionPolicy -Scope Process Bypass`.

---

## Gün 7 — Operasyon ekranındaki eksikler

Bugünün işi: Gün 6'da ekranın cevaplayamadığı sorular kapatıldı ve mutabakattaki gereksiz ERP sorguları kaldırıldı.

- **Takılı faturalar:** fatura listesinde `Takılı` süzgeci (`GET /invoices?stuck=true`); özetteki kart listeyi bu süzgeçle açar.
  Liste ve özet aynı koşulu kullanır.
- **ERP'nin karar vermediği fatura:** `ERP Karar Vermedi` bulgusu (`NoDecisionAfterMinutes`, 30 dk); fatura detayında ve
  mutabakat sayfasında görünür, detayda yalnızca en sonuncusu.
- **Müdahaleyi kimin yaptığı:** ekran ilk açılışta adı sorar; yeniden gönderme, toplu yeniden gönderme ve mutabakat başlatma
  `X-Operator-Name` ister (yoksa `400`) ve `operator_actions`'a yazılır; fatura detayında müdahaleler, mutabakat sayfasında
  başlatan görünür.
- **Mutabakatta gereksiz sorgular:** ERP'nin "yok" dediği Başarısız fatura `NotFoundRecheckHours` (24 saat) yeniden sorulmaz;
  takip `invoices.erp_checked_at` / `erp_check_result` ile yapılır, fatura detayında "mutabakatın ERP'ye son sorusu" olarak da
  görünür. Çalışma listesi sayfalıdır (en çok 50).

Kontrol listesi: [`manual-tests/gun7/`](manual-tests/gun7/README.md) (1, 3, 5-8. maddelerin script'leri ve
`kontrol-listesi.ps1`; 2 ve 4. maddelerin ekranda adımları).

### Son doğrulama — 7 Ekim 2026

Sekiz madde gerçek PostgreSQL, HTTP ve tarayıcıyla koşuldu ve hepsi geçti; her maddede sonuç veritabanıyla karşılaştırıldı.
Birim testler: Invoice Service 338, ERP Simulator 103, operasyon ekranı 20, hepsi geçti. Gün 6 kontrol listesi de yeniden
koşuldu: ilk koşuda 2. madde (düzeltmesi hata veren fatura) kaldı; ERP'nin cevabı bütün faturalara tek UPDATE ile yazıldığı için
bir faturanın hatası çalışmanın tamamını düşürüyordu. Cevap fatura başına yazılacak şekilde düzeltildi, iki liste de baştan
koşuldu ve hepsi geçti.

| # | Senaryo | Sonuç |
|---|---|---|
| 1 | Takılı süzgeci = özetteki sayı = veritabanı | 3 fatura 10 dk önce, 1 fatura az önce `Gönderildi` yapıldı: listede, özette ve veritabanında 6 takılı fatura, numaralar aynı; yeni olan listede yok. Süzgeç durum ve aramayla birlikte de doğru |
| 2 | Özetteki takılı kartı | Kart listeyi `?durum=Takılı` ile açtı, Durum seçiminde Takılı, listede karttaki sayı kadar (3) fatura |
| 3 | ERP'nin kararı gecikince | Simülatörde karar 240 sn sonraya alındı ve karar haberi gönderilmedi, eşikler 1 / 2 dk'ya indirildi: iki çalışma `ERP Karar Vermedi` raporladı (ERP cevabı `received`), detayda yalnızca sonuncusu, mutabakat sayfasında çalışmanın bulgusu; karar oluştuktan sonraki çalışma faturayı `Reddedildi` yaptı (`Takılı Fatura`, Düzeltildi) |
| 4 | Ad | Tarayıcı verisi silinince ekran adı sordu; yenilemede sormadı; ad üst çubukta |
| 5 | `operator_actions` | Tekli yeniden gönderme: `Kuyruğa alındı`, ikinci deneme `Reddedildi: fatura Bekliyor`. Toplu (3 Başarısız, 1 Onaylandı, 1 olmayan): 5 satır, her biri kendi sonucuyla. Mutabakat: aynı anda iki başlatma, biri `Başlatıldı: çalışma N` (çalışmanın `started_by`'ı aynı ad), diğeri `Reddedildi: başka bir çalışma sürüyor`. Türkçe karakterli ad doğru kaydedildi |
| 6 | Başlıksız istekler | Üç istek, başlık yok / boş / yalnızca boşluk: `400` (`operator_name_required`); hiçbir şey yazılmadı, fatura değişmedi, çalışma başlamadı |
| 7 | ERP'nin hiç almadığı 50 eski Başarısız fatura | İlk çalışma 50 sorgu (hepsi `NotFound`, loglarda fatura başına satır), ikinci çalışma 0 sorgu (`skippedRecentlyNotFound`); faturalardan biri değişince sonraki çalışma yalnızca onu sordu |
| 8 | 120'den fazla çalışma | 50'lik sayfalarla bütün çalışmalar bir kez ve veritabanıyla aynı sırada okundu; `pageSize=51` ve `page=0` `400` |

Ek: zamanlayıcının başlattığı çalışmada `started_by` `Zamanlayıcı`, `operator_actions`'a kayıt yok. Gün 6'da bilinen sınır
olarak yazılan, ERP'nin hiç karar vermediği üç fatura (FTR-004135..137) artık her çalışmada `ERP Karar Vermedi` alıyor.

Testte izlenen yol: 1. maddede takılı faturalar, 7. maddede eski Başarısız faturalar, 8. maddede eksik kalan çalışmalar SQL ile
üretildi. 3. maddede simülatörün `Webhooks:SecondEventMin/MaxSeconds` ve `LostDecisionRate` ayarları ile servisin
`StuckAfterMinutes` / `NoDecisionAfterMinutes` ayarları geçici olarak değiştirildi; sonunda varsayılana döndü.

### Bilinen sınırlar

- **Ad bir kayıttır, kimlik değildir:** ekranı açan herkes istediği adı yazabilir; API'yi doğrudan çağıran herhangi bir adı gönderebilir.
- **Takılı sayısı zamana bağlıdır:** özet ve liste aynı koşulu kullanır, ama farklı anlarda istenirlerse arada 2 dakikayı geçen bir
  fatura birinde sayılıp diğerinde sayılmayabilir. Kuyrukta (`Bekliyor`) uzun kalan fatura hâlâ takılı sayılmaz.
- **`ERP Karar Vermedi` her çalışmada yazılır:** ERP sessiz kaldıkça bulgu tablosu fatura başına çalışma sayısı kadar büyür (detay yalnızca
  sonuncusunu gösterir). Fatura elle takibe alınmaz; karar gelince mutabakat düzeltir.
- **Yalnızca Başarısız faturada atlanır:** pencerenin dışındaki `Gönderildi` fatura ERP'de yoksa her çalışmada sorulur ve
  `ERP Kaydı Yok` olarak raporlanır. ERP'ye ulaşılamadığı için başarısız olan çalışmada o ana kadar alınan cevaplar kaydedilmez;
  faturaya yazılamayan cevap da yalnızca loga düşer. İkisinde de o fatura sonraki çalışmada yeniden sorulur.
- **Kayıtların yazılamadığı durum:** toplu gönderimde hata veren faturanın `Hata` kaydı ve mutabakat zaten çalışırken gelen başlatma
  isteğinin kaydı ayrı yazılır; veritabanı o anda da yazmıyorsa yalnızca loga düşer.
- **Eski çalışmalar:** Gün 7'den önceki çalışmaların başlatanı bilinmez (ekranda `—`).
- **Çalışma listesi:** sayfalar arasında yeni bir çalışma başlarsa sonraki sayfa bir kayıt kayar (listeler id'ye göre en yeni üstte).
- **Detay tek anlık görüntü değildir** ve **ekranın adresi derlemede gömülür** (değişmedi).
- **Yerel test verisi:** 50 `QA7-ESKI` Başarısız fatura, 72 `QA7-sayfa` çalışması ve 3 kalıcı takılı fatura veritabanında kaldı.

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
