# Staj_Tasks

Fatura entegrasyonu üzerine staj projesi: Invoice Service ve ona hata üreterek cevap veren, sonra faturanın sonucunu
imzalı webhook'larla bildiren ERP Simulator.

| Uygulama | Klasör | Ne yapar |
|---|---|---|
| ERP Simulator | `erp-simulator/` | Faturaları kabul eden ERP'yi taklit eder; her isteğe seed'li rastgele bir hata davranışı uygular; kaydettiği faturalar için Invoice Service'e imzalı webhook gönderir (bilerek sorunlu) |
| Invoice Service | `invoice-service/` | Faturayı ve Outbox kaydını birlikte kaydeder; arka planda ERP'ye gönderir; ERP'den gelen webhook event'lerini doğrulayıp faturaya işler; belirli aralıklarla kendi kayıtlarını ERP'ninkiyle karşılaştırır (mutabakat), düzeltebildiğini düzeltir, düzeltemediğini raporlar |

İki uygulama da Domain / Application / Infrastructure / Api olarak dört katmana ayrılmıştır; katmanlar, port'lar,
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
| `invoices` | Fatura ve durumu. Numarayı servis üretir (sequence → `FTR-000001`; body'deki `invoiceNumber` yok sayılır). `send_attempt_count` ömür boyu sayaçtır, resend'de sıfırlanmaz. `reject_reason` yalnızca `Reddedildi`'de dolu |
| `erp_outbox` | Faturanın Outbox kaydı (fatura başına bir satır). `locked_until` / `locked_by` / `claim_token` sahipliği ve eski alımın sonucunun yenisini ezmesini önler |
| `erp_webhook_events` | Gelen her geçerli event bir satır (`event_id` birincil anahtar). `delivery_count` tekrar gelişi sayar, `ignore_reason` `Yok Sayıldı`'nın nedenidir (`Geri Götürüyor`, `Kesin Durumda`, `İlerletmiyor`, `Referans Farklı`, `Fatura Yok`) |
| `reconciliation_runs` | Bir mutabakat çalışması: durum (`Çalışıyor` / `Tamamlandı` / `Başarısız`), karşılaştırılan, düzeltilen ve raporlanan sayısı, hata |
| `reconciliation_findings` | Çalışmanın bulduğu fark: tür, eylem (`Düzeltildi` / `Raporlandı`), ayrıntı. `Düzeltildi` yalnızca düzeltilen üç türde olabilir (check constraint). Fatura tablosuna foreign key yoktur: ERP'de olup serviste olmayan fatura da raporlanır |

`invoices.status`: `Bekliyor` → `Gönderildi` ya da `Başarısız`; ERP event'leriyle `Gönderildi` → `İşleme Alındı` →
`Onaylandı` / `Reddedildi` (`Gönderildi`'den doğrudan karar da olur). `Onaylandı` ve `Reddedildi` kesin durumdur.
`Başarısız`: bütün denemeler tükendiğinde ya da ERP Simulator 429 dışında bir 4xx döndüğünde; yalnızca resend onu
yeniden kuyruğa alır. Durum değerleri ve alanlar veritabanında check constraint ile sınırlıdır.

### Endpoint'ler

| Endpoint | Davranış |
|---|---|
| `POST /api/v1/invoices` | Body: `customerCode`, `amount`, `currency`, `invoiceDate`. Fatura `Bekliyor` durumunda ve `erp_outbox` kaydıyla aynı transaction'da yazılır, `202`. ERP Simulator bu istekte çağrılmaz. Geçersiz body `400` (tutarda virgülden sonra en fazla iki basamak), hiçbir şey kaydedilmez. |
| `POST /api/v1/invoices/{invoiceNumber}/resend` | Yalnızca `Başarısız` fatura için: Outbox kaydını sıfırlar (`Bekliyor`, 0 deneme, hemen), faturayı `Bekliyor` yapar, `202`. `Başarısız` değilse `409`, yoksa `404`. Aynı anda iki resend gelirse biri `202`, diğeri `409` alır. |
| `GET /api/v1/invoices?status=Bekliyor` | O durumdaki faturalar; `status` verilmezse hepsi, geçersizse `400`. |
| `GET /api/v1/invoices/{invoiceNumber}` | Faturanın servisteki hali (`200`, `rejectReason` dahil) ya da `404`. |
| `POST /api/v1/reconciliation-runs` | Mutabakatı elle başlatır: `202` + `Location` + çalışma (`Çalışıyor`); çalışma arka planda sürer. Başka bir çalışma sürüyorsa (zamanlanmış, elle ya da servisin diğer kopyasında) `409`. |
| `GET /api/v1/reconciliation-runs` | Çalışmalar, en yeniden eskiye (bulgusuz). |
| `GET /api/v1/reconciliation-runs/{id}` | `{ run, findings[] }` ya da `404`. |
| `POST /api/v1/erp-webhooks` | ERP webhook event'i. İmza header'ları yok/yanlış ya da timestamp 5 dk'dan eski veya ileri: `401`, kaydedilmez. İmza doğru ama body geçersiz: `400`; 64 KB'tan büyük body: `413`. Event 4 sn içinde işlenemezse `503` (ERP tekrar gönderir). Aksi halde `200` + `{eventId, status, repeat}`. |

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

- **Aynı anda tek çalışma:** PostgreSQL advisory lock. Zamanlanmış çalışma, elle başlatma ve servisin ikinci kopyası
  aynı kilidi kullanır; kilit başkasındaysa `POST` `409` alır, zamanlanmış tur atlanır. Kilit bağlantıya bağlıdır:
  kopya çökerse veritabanı bırakır.
- **Event'le çakışma:** bir fatura düzeltilirken satırının lock'u (`SELECT … FOR UPDATE`) tutulur; event aynı lock'u
  alır, resend ise aynı satırı güncellediği için lock tutulurken bekler. Lock alındıktan sonra fatura planın gördüğü
  durumda değilse o fatura bırakılır.
- Düzeltilmeyenler hangi tarafın doğru olduğunu bilmeyi gerektirir; bu yüzden yalnızca raporlanır.
- **Düzeltmesi hata veren fatura:** düzeltmenin transaction'ı geri alınır, fatura değişmez, kalan düzeltmeler sürer. Fatura aynı
  türde, `Raporlandı` olarak ve ayrıntısı "Düzeltme uygulanamadı: <neden>" diye kaydedilir; bir sonraki çalışma yeniden dener.

### Ayarlar

[`appsettings.json`](invoice-service/src/InvoiceService.Api/appsettings.json): her değerin yanında ne işe yaradığı ve
neden o değerde olduğu yazılı. Hepsi zorunludur; eksik ya da kurala aykırıysa servis açılmaz ve nedenini yazar.
Değişiklikten sonra `docker compose up -d --build invoice-service`. Docker'da ERP adresi `appsettings.Docker.json`'dadır.
`ErpWebhooks:Secret`, ERP Simulator'daki `Webhooks:Secret` ile aynı olmalıdır.

Mutabakat ayarları: `IntervalMinutes` 60, `LookbackHours` 24, `StuckAfterMinutes` 2, `UnknownEventAfterMinutes` 60.
Testler aralığı `Reconciliation__IntervalMinutes` ortam değişkeniyle 1'e çeker (`docker-compose.yml`'de geçişi var).

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

## Gün 5 — Mutabakat

Bugünün işi: Invoice Service belirli aralıklarla kendi kayıtlarını ERP Simulator'la karşılaştırıyor, düzeltebildiğini
düzeltiyor, düzeltemediğini raporluyor ([Mutabakat](#mutabakat)). ERP Simulator bunun için `GET /api/v1/invoices/{n}`
cevabında faturanın kararını döndürüyor ve kayıtlarını `GET /api/v1/invoices?from&to` ile sayfalı listeliyor
([Endpoint'ler](#endpointler)). İki yeni tablo eklendi (`reconciliation_runs`, `reconciliation_findings`), `ignore_reason`'a
`Fatura Yok` eklendi. Önce kod sadeleştirildi: iki uygulama katmanlı yapıya alındı, açıklamalar kısaltıldı
([ARCHITECTURE.md](ARCHITECTURE.md)). Sonradan iki düzeltme eklendi: durumu kesinleşmemiş faturalar yaşlarına bakılmadan
her çalışmada kontrol ediliyor, düzeltmesi hata veren fatura nedeniyle birlikte bulgu olarak kaydediliyor.

Kontrol listesi ve ek testler: [`manual-tests/gun5/`](manual-tests/gun5/) (`.\manual-tests\gun5\kontrol-listesi.ps1` 2-9.
maddeleri sırayla çalıştırır; 1. madde `gun3` ve `gun4` listeleridir).

### Son doğrulama — 5-6 Ekim 2026

Gün 3 listesi (7/7, 21,9 dk), Gün 4 listesi (8/8, 9,3 dk), Gün 5 listesi (2-9, 17,6 dk) ve ek testler 6 Ekim'de son kodla
koşuldu ve hepsi geçti. Gün 3'ün daha önceki bir koşusunda 4. madde, beklemeyi iki log damgasından ölçtüğü için,
planlanandan 87 ms kısa ölçülmüştü, 50 ms toleransı 37 ms aşmıştı; tolerans değiştirilmeden yeniden koşularda geçti.
Birim testler: Invoice Service 292, ERP Simulator 103, hepsi geçti. Bunlar bu koşuların sonuçlarıdır; başka koşullarda aynı
sonucun çıkacağını göstermez.

| # | Senaryo | Sonuç |
|---|---|---|
| 1 | Sadeleştirmeden sonra Gün 3 ve Gün 4 | Gün 3 7/7, Gün 4 8/8 (son kodla) |
| 2 | 500 fatura, varsayılan oranlar, haberler bitince mutabakat | 30 fatura takılı kalmıştı (karar event'i gönderilmeyen 30'la aynı); 30'u düzeltildi, kalan 0 |
| 3 | ERP Simulator'a elle eklenen, serviste olmayan fatura | `Serviste Yok` raporlandı; iki tarafta değişiklik yok. `POST` `202` + `Location`, liste sırası ve `404` de doğrulandı |
| 4 | ERP'de tutarı elle değiştirilen fatura | `Alan Farkı` (1250.50 / 1260.50) raporlandı; değişiklik yok |
| 5 | Elle ikinci gönderim (çift kayıt) | `ERP Çift Kayıt` raporlandı; aynı fatura serviste `Başarısız` olsa da yalnızca raporlandı, fatura ve `erp_outbox` değişmedi |
| 6 | Serviste elle `Başarısız` yapılan, referansı boşaltılan fatura | `Başarısız Ama ERP Kayıtlı` düzeltildi: `Gönderildi`, ERP'deki referans, `erp_outbox` `Tamamlandı` |
| 7 | Tanınmayan faturaya geçerli imzalı event, eşik 1 dk | Zamanlanmış çalışma 125 sn sonra `Yok Sayıldı` (`Fatura Yok`) yaptı; fatura oluşmadı |
| 8 | Servisin iki kopyası + elle başlatma | Kilit başka oturumdayken iki kopya da `409`; 30 eşzamanlı istekte 1 `202`, 29 `409`; çalışma aralıkları üst üste binmedi |
| 9 | Mutabakat sürerken ERP Simulator ulaşılamaz | Çalışma `Başarısız` (10 sn zaman aşımı), hiçbir fatura değişmedi; sonraki çalışma 5 faturanın 5'ini düzeltti |

**Ek testler:**
- `ek-haber-yarisi.ps1`: fatura satırı 8 sn kilitliyken mutabakat başlatıldı ve kararın event'i servise gönderildi. Event iki
  kez `503` (lock-timeout) aldı, sonra `200`; fatura tek kez doğru karara ilerledi. İki sıra da görüldü (mutabakat önce: ilk
  koşuda, event önce: sonraki koşularda), ikisinde de sonuç tutarlıydı.
- `ek-eski-takili-fatura.ps1`: 3 gün öncesine alınan `Gönderildi`'de takılı fatura ERP'nin kararını aldı, `Başarısız` fatura
  geri geldi ve kararı aldı, kesinleşmiş eski faturaya dokunulmadı.
- `ek-duzeltme-hatasi.ps1`: veritabanı trigger'ı bir faturanın güncellemesini hataya düşürdü; çalışma `Tamamlandı`, o fatura
  nedeniyle (`Düzeltme uygulanamadı: ...`) `Raporlandı` ve değişmedi, diğeri düzeltildi; trigger kalkınca sonraki çalışma düzeltti.

Yerel ham çıktılar `manual-tests/output/` altındadır (Git'e dahil değildir).

### Bilinen sınırlar

- **Pencere:** kesinleşmiş (`Onaylandı`, `Reddedildi`) faturalar yalnızca son `LookbackHours` saatte oluşmuşsa karşılaştırılır.
  Kesinleşmemiş faturalar yaşına bakılmadan her çalışmada kontrol edilir; pencerenin dışındakiler için ERP Simulator'a
  tek tek sorulur, bu yüzden uzun bir kesintiden sonra takılı kalan fatura kaçmaz. Çok sayıda eski `Başarısız` fatura
  birikirse her çalışmada o kadar sorgu atılır.
- **Aralık:** zamanlanmış çalışmanın ve iki kopyanın sınandığı 7. ve 8. maddede aralık ortam değişkeniyle 1 dk'ya çekilir; 1 dk'da mutabakat karar event'i gelmemiş faturaları da düzeltir ve Gün 4'ün
  3. maddesinin sayımını (kalan fatura = karar event'i gönderilmeyen fatura) değiştirir.
- **9. madde:** ERP Simulator kapatılmadı, `docker pause` ile donduruldu; kesinti çalışmanın ERP'den ilk okumasında
  oluştu. Karar sorgusu aşamasındaki kesinti yalnızca unit testle doğrulandı.
- **Düzeltilmeyenler:** içeriği (tutar, para birimi, müşteri kodu, referans) ERP'den farklı fatura ERP'nin referansıyla ya
  da kararıyla ilerletilmez, yalnızca raporlanır. ERP'de birden fazla kaydı olan fatura da geri getirilmez ve karar
  almaz, yalnızca raporlanır: hangi kaydın doğru olduğu bilinmez.
- **Yorum gerektirenler:** `decision` ilk event zamanı gelince `received`, karar zamanı gelince `approved` / `rejected`
  döner; `pageSize` 500'ü aşarsa `400` döner; `ERP Kaydı Yok` istenen türlerin
  dışında eklenmiş bir türdür; `Başarısız` olup ERP'de birden fazla kaydı olan faturada çift kayıt kuralına öncelik
  verilir: yalnızca `ERP Çift Kayıt` raporlanır, fatura düzeltilmez.
- **Ölçek:** düzeltmeler ve karar sorguları sıralıdır; çalışma listesi sayfalanmaz. Her çalışma penceredeki bütün
  faturaları ve ERP kayıtlarını belleğe alır; test ölçeğinde (binlerce fatura) sorun olmadı, çok büyük hacimde ayrıca
  ele alınması gerekir.
- **Kilit:** bağlantı canlı tutulur (keepalive) ama ağ gerçekten kopmuşsa kilit düşer ve ikinci bir çalışma başlayabilir;
  bunu yakalayan ek bir kontrol yoktur.
- **Test kapsamı:** Uygulama kuralları birim testlerle (bellek içi sahtelerle); SQL store'ları, advisory lock, endpoint'ler
  ve seçili eşzamanlılık senaryoları gerçek PostgreSQL kullanan `manual-tests/gun5/` script'leriyle (docker gerekir)
  doğrulanır; bütün eşzamanlılık ihtimalleri denenmemiştir. Event ile
  mutabakat yarışı canlı denendi (`ek-haber-yarisi.ps1`); resend ile mutabakat yarışı denenmedi, yalnızca kod
  okumasıyla (resend satırı güncellediği için lock tutulurken bekler) değerlendirildi.

---

## Günler

| Tag | Gün | O günün hali |
|---|---|---|
| `gun-1` | ERP Simulator | [tree/gun-1](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-1) |
| `gun-2` | Invoice Service'in ilk sürümü | [tree/gun-2](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-2) |
| `gun-3` | Güvenli Gönderim | [tree/gun-3](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-3) |
| `gun-4` | ERP'den Gelen Haberler | [tree/gun-4](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-4) |
| `gun-5` | Mutabakat | [tree/gun-5](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-5) |
