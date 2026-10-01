# Staj_Tasks

Fatura entegrasyonu üzerine staj projesi: bir fatura servisi ve ona hata üreterek cevap veren bir ERP simülatörü.

| Uygulama | Klasör | Ne yapar |
|---|---|---|
| ERP Simülatörü | `erp-simulator/` | Faturaları kabul eden ERP'yi taklit eder; her isteğe seed'li rastgele bir hata davranışı uygular |
| Fatura Servisi | `invoice-service/` | Faturayı kaydeder, ERP Simülatörü'ne gönderir ve sonucu yazar |

Her günün teslim edilen hali bir git tag'idir; README yalnızca uygulamaları ve **bugünün** işini anlatır.
Önceki günlerin anlatımı ve sonuçları kendi tag'inde durur (bkz. [Günler](#günler)).

## Kurulum

```bash
docker compose up -d --build
```

| Servis | Adres |
|---|---|
| ERP Simülatörü | http://localhost:5080 (Swagger: http://localhost:5080/swagger) |
| ERP veritabanı | `localhost:5433` — db `erp_simulator`, kullanıcı `erp`, şifre `erp` |
| Fatura Servisi | http://localhost:5090 (Swagger: http://localhost:5090/swagger) |
| Fatura veritabanı | `localhost:5434` — db `invoice_service`, kullanıcı `invoice`, şifre `invoice` |

İki veritabanı ayrı container'larda, ayrı kullanıcı/şifreyle çalışır. Her uygulamanın yalnızca kendi veritabanının
bağlantı bilgisi ve şifresi vardır; iki uygulama birbirine yalnızca `apps` ağı üzerinden HTTP ile ulaşır.
Veritabanları ayrıca ayrı docker ağlarındadır, bu yüzden karşı uygulama veritabanının adını çözemez. Ancak ayrı ağlar
IP ile erişimi her ortamda engellemez (Docker Desktop'ta engellemiyor); ayrılığı sağlayan, bağlantı bilgileridir.

Her iki uygulamada da şema EF Core migration ile açılışta otomatik oluşur.

---

## ERP Simülatörü

.NET 10, ASP.NET Core Minimal API, kendi PostgreSQL veritabanı (`erp-db`).

### Endpoint'ler

| Endpoint | Davranış |
|---|---|
| `POST /api/v1/invoices` | Gövde: `invoiceNumber`, `customerCode`, `amount`, `currency`, `invoiceDate`. Seçilen davranışa göre cevap verir (aşağıda). Eksik/geçersiz alan `400`. |
| `GET /api/v1/invoices/{faturaNumarası}` | `200` + `registered`, `erpReference` (ilk kayıt), `recordCount`, `records[]`. Kayıt yoksa `404`. Hata üretmez. |

```json
POST /api/v1/invoices
{ "invoiceNumber": "INV-2026-0001", "customerCode": "C-001", "amount": 1250.50, "currency": "TRY", "invoiceDate": "2026-09-29" }

202 Accepted
{ "erpReference": "ERP-00000001", "invoiceNumber": "INV-2026-0001", "receivedAt": "2026-09-29T07:00:00+00:00" }
```

### Davranışlar

Her POST için aşağıdaki davranışlardan biri seed'li rastgele seçimle seçilir. Oranlar gerçek yüzdedir:

| Davranış | Varsayılan oran | Cevap | Fatura kaydedilir mi |
|---|---|---|---|
| `Success` | %60 | `202` + ERP referansı | Evet |
| `Busy` | %15 | `429` + `Retry-After` (5–30 sn) | Hayır |
| `ServerError` | %10 | `500` | Hayır |
| `SaveThenError` | %5 | `500` | Evet |
| `LateResponse` | %10 | 30 sn bekleyip `202` | Evet (kayıt istek gelince yapılır, yalnızca cevap gecikir) |

- **Retry-After** iki biçimde gönderilebilir (RFC 9110): saniye `Retry-After: 17` (varsayılan) veya HTTP-date
  `Retry-After: Tue, 29 Sep 2026 07:00:17 GMT`; `RetryAfterFormat` ayarıyla seçilir.
- **Çift kayıt varsayılan olarak engellenmez:** aynı fatura numarası her gelişte yeni ERP referansıyla yeni kayıt açar.
  `IdempotentInvoices` ayarı açılırsa (aşağıda) aynı numara ikinci kez kaydedilmez.
- **Seed:** aynı seed + aynı istek sırası = aynı davranış dizisi. Simülatör yeniden başlayınca dizi baştan başlar.
- **Log:** her istek seçilen davranışla loglanır: `ERP request #12 invoice=INV-2026-0001 behavior=Busy status=429 retryAfter=17s`

### Ayarlar

[`erp-simulator/src/ErpSimulator/appsettings.json`](erp-simulator/src/ErpSimulator/appsettings.json) — container'a mount edilir, değişiklikten sonra `docker compose restart erp-simulator`.

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
- `Success` 100, hata oranlarının hepsi 0 ise simülatör kusursuz bir ERP gibi davranır.
- **`IdempotentInvoices`** (varsayılan `false`): `false` iken her POST yeni kayıt açar (yukarıdaki davranış). `true` iken
  aynı fatura numarasıyla gelen istekler sırayla işlenir (ilk isteğin kaydı tamamlanana kadar ikincisi bekler) ve numara
  zaten kayıtlıysa yeniden kaydedilmez: içerik aynıysa mevcut referansla `202` (davranış seçilmez, logda
  `behavior=Duplicate`), farklıysa `409`. Veritabanına unique index eklenmedi: eski çift kayıtlar geçerli kalır ve ayar
  geri kapatılabilir.
- Açılışta ayarlar loglanır: `Simulator settings: seed=42 success=60% busy=15% ... (total=100) ...`

Tek seferlik değişiklik ortam değişkeniyle de yapılabilir (toplam yine 100 olmalı):

```powershell
$env:Simulator__Rates__Success=0; $env:Simulator__Rates__Busy=100; $env:Simulator__Rates__ServerError=0; $env:Simulator__Rates__SaveThenError=0; $env:Simulator__Rates__LateResponse=0; docker compose up -d --force-recreate erp-simulator
```

---

## Fatura Servisi

.NET 10, ASP.NET Core Minimal API, kendi PostgreSQL veritabanı (`invoice-db`).

Fatura isteğin içinde ERP'ye gönderilmez: fatura ve bir "gönderilecekler" kaydı (`erp_outbox`) aynı transaction'da
yazılır, istek hemen `202` döner. Arka plandaki worker kuyruktan sırası gelenleri simülatöre gönderir, hataya göre
bekleyip tekrar dener ve sonucu yazar (outbox pattern).

### Veri

- **`invoices`**: `invoice_number`, `customer_code`, `amount`, `currency`, `invoice_date`, `status`, `erp_reference`,
  `last_error`, `send_attempt_count`, `created_at`, `updated_at`.
  - Fatura numarasını servis üretir: PostgreSQL sequence → `FTR-000001`. Gövdede gönderilen `invoiceNumber` yok sayılır.
  - `status`: `Bekliyor` → `Gönderildi` ya da `Başarısız` (veritabanında check constraint). `Başarısız` kalıcıdır:
    bütün denemeler tükendiğinde ya da simülatör 429 dışında bir 4xx döndüğünde. Yalnızca resend onu yeniden kuyruğa alır.
  - `send_attempt_count`: faturanın ömrü boyunca yapılan deneme sayısı; resend'de sıfırlanmaz.
- **`erp_outbox`**: faturanın gönderim kaydı, fatura başına bir satır (`invoice_number` unique).
  `id`, `invoice_number`, `status` (`Bekliyor` / `Tamamlandı` / `Başarısız`), `attempt_count`, `next_attempt_at`,
  `last_error`, `created_at`, `processed_at` ve eklenen üç kolon: `locked_until`, `locked_by`, `claim_token`
  (neden gerektikleri aşağıda, Gün 3 bölümünde).

### Endpoint'ler

| Endpoint | Davranış |
|---|---|
| `POST /api/v1/invoices` | Gövde: `customerCode`, `amount`, `currency`, `invoiceDate`. Fatura `Bekliyor` durumunda ve `erp_outbox` kaydıyla aynı transaction'da yazılır, `202`. Simülatör bu istekte çağrılmaz. Geçersiz gövde `400`, hiçbir şey kaydedilmez. |
| `POST /api/v1/invoices/{faturaNumarası}/resend` | Yalnızca `Başarısız` fatura için. Simülatöre gitmez: outbox kaydını sıfırlar (`Bekliyor`, 0 deneme, hemen) ve faturayı `Bekliyor` yapar, `202`. `Başarısız` değilse `409`, yoksa `404`. Aynı anda iki resend gelirse biri `202`, diğeri `409` alır. |
| `GET /api/v1/invoices?status=Bekliyor` | O durumdaki faturalar (`Bekliyor`, `Gönderildi`, `Başarısız`); `status` verilmezse hepsi, geçersizse `400`. Testlerde kuyruğun boşalmasını beklemek için. |
| `GET /api/v1/invoices/{faturaNumarası}` | Faturanın servisteki hali (`200`) ya da `404`. |

### Gönderim (worker)

- Worker kuyruktan zamanı gelmiş (`next_attempt_at` geçmiş, kilitsiz) kayıtları tek bir SQL cümlesiyle alır
  (`FOR UPDATE SKIP LOCKED`); kayda `locked_until`, `locked_by`, yeni bir `claim_token` yazar ve deneme sayısını
  gönderimden **önce** artırır. Aynı anda en fazla `MaxConcurrentSends` (10) gönderim yapar.
- Tekrar deneme kuralları:

  | Simülatörün cevabı | Ne olur |
  |---|---|
  | `202` | `Gönderildi` + `erp_reference`, outbox `Tamamlandı` |
  | `429` | `Retry-After` kadar beklenir (saniye ya da tarih biçimi); jitter eklenmez |
  | `500`, 10 sn zaman aşımı, ulaşılamama | 2, 4, 8 … sn (deneme numarasına göre katlanarak), en fazla 60 sn, üzerine 0–1 sn rastgele jitter |
  | 429 dışında 4xx | Hemen `Başarısız`, tekrar denenmez |
  | 10. deneme de başarısız | `Başarısız` (fatura ve outbox) |

- **Çift kayıt koruması:** fatura daha önce gönderilmeye çalışıldıysa servis POST'tan önce simülatöre `GET` ile sorar:
  varsa referansı alır (POST yok), açıkça `404` ise gönderir, sorulamazsa göndermez ve sonra tekrar dener. Hakları
  bitince faturayı `Başarısız` yapmadan önce bir kez daha sorar.
- **Servis öldürülürse:** kaydın kilidi `LockSeconds` (60 sn) sonra dolar ve kayıt yeniden alınır; sonuç yalnızca
  kayıt hâlâ o alımın `claim_token`'ını taşıyorsa yazılır.
- Her deneme loglanır:
  `ERP send invoice=FTR-000042 attempt=3/10 worker=… claim=1a2b3c4d check=notFound outcome=Retry http=500 … wait=8.412s reason=…`

### Ayarlar

[`invoice-service/src/InvoiceService/appsettings.json`](invoice-service/src/InvoiceService/appsettings.json) — her
değerin yanında ne işe yaradığı ve görevden mi geldiği, bizim seçimimiz mi olduğu yorum olarak yazılı. Hepsi zorunludur;
eksik ya da kurala aykırıysa servis açılmaz ve nedenini yazar. Değişiklikten sonra `docker compose up -d --build invoice-service`.

| Ayar | Değer | Kaynak |
|---|---|---|
| `Erp:BaseUrl` | `http://localhost:5080` | compose içinde `http://erp-simulator:8080` |
| `Erp:TimeoutSeconds` | `10` | Görev (`HttpClient`'ın varsayılanı 100 sn; simülatörün geç cevabı 30 sn) |
| `Outbox:MaxConcurrentSends` | `10` | Görev; servis kopyası başına |
| `Outbox:MaxAttempts` | `10` | Görev |
| `Outbox:MaxBackoffSeconds` | `60` | Görev; jitter dahil tavan |
| `Outbox:MaxJitterMilliseconds` | `1000` | Bizim seçimimiz |
| `Outbox:BackoffMarginMilliseconds` | `0` | Bizim seçimimiz; tavanın altında bırakılan pay |
| `Outbox:LockSeconds` | `60` | Bizim seçimimiz; `3 × TimeoutSeconds`'tan uzun olmak zorunda |
| `Outbox:IdleDelayMilliseconds` | `250` | Bizim seçimimiz; kuyrukta iş yokken bekleme |

Açılışta ayarlar loglanır: `ERP settings: …`.

### İkinci kopya

`docker-compose.yml`'de aynı veritabanını kullanan ikinci bir kopya var (`invoice-service-2`, port `5091`, profil
`iki-kopya`); düz `docker compose up` onu başlatmaz:

```bash
docker compose --profile iki-kopya up -d invoice-service-2
```

---

## Testler

| Ne | Komut |
|---|---|
| Unit testler | `dotnet test erp-simulator` ve `dotnet test invoice-service` |
| Elle testler — Gün 3 kontrol listesi, adım ve ek testleri | [`manual-tests/gun3/`](manual-tests/gun3/README.md) |
| Elle testler — ERP Simülatörü | [`manual-tests/gun1/`](manual-tests/gun1/README.md) |
| Simülatör veritabanı / logları | `.\manual-tests\gun1\db.ps1`, `.\manual-tests\gun1\loglar.ps1` |
| Fatura Servisi veritabanı | `.\manual-tests\gun2\db.ps1` |
| Simülatör uçtan uca kontrol (bash) | `./scripts/erp-simulator-checklist.sh` |
| Simülatör dağılım ölçümü (bash) | `./scripts/erp-simulator-distribution.sh <adet>` |

`manual-tests/gun2/` içindeki kontrol listesi script'leri Gün 2'deki eşzamanlı gönderimi (`201`, resend'in doğrudan
göndermesi) test eder; [gun-2](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-2) tag'inde çalıştırılmalıdır.
Gün 3 script'leri onun yardımcılarını (`_common.ps1`, `db.ps1`) kullanmaya devam eder.

Elle deneme: Swagger UI (yukarıdaki adresler) veya `.http` dosyaları
([simülatör](erp-simulator/src/ErpSimulator/ErpSimulator.http), [servis](invoice-service/src/InvoiceService/InvoiceService.http));
loglar için `docker compose logs -f erp-simulator` / `docker compose logs -f invoice-service`.
Script'ler engellenirse önce `Set-ExecutionPolicy -Scope Process Bypass`.

---

## Gün 3 — Güvenli Gönderim

Bugünün işi: gönderimin arka plana alınması (outbox + worker), tekrar deneme kuralları, çift kayıt koruması, resend'in
yalnızca kuyruğa alması ve listeleme endpoint'i. Kontrol listesi, adım testleri ve ek testler:
[`manual-tests/gun3/`](manual-tests/gun3/README.md) (`.\manual-tests\gun3\kontrol-listesi.ps1` 7 maddeyi sırayla çalıştırır).

### 1) Outbox pattern nedir, hangi sorunu çözer

**Çözdüğü sorun: iki ayrı yere yazma ("dual write").** Fatura oluşturmak aslında iki iş: faturayı kendi veritabanımıza
yazmak ve onu ERP'ye göndermek. Bu ikisi tek bir işlemde yapılamaz (biri veritabanı, diğeri ağ üzerinden başka bir
sistem). Hangi sırayla yapılırsa yapılsın arada bir şey ters giderse tutarsızlık olur:
- Önce kaydedip sonra ERP'ye gönderirsek ve gönderim sırasında servis çökerse ya da ERP cevap vermezse, fatura bizde var
  ama ERP'ye gitmemiş olur ve kimse onu tekrar göndermez (Gün 2'de "kaybolan" faturalar buydu).
- Önce ERP'ye gönderip sonra kaydedersek ve kayıt başarısız olursa, ERP'de bizim bilmediğimiz bir fatura olur.

**Çözüm:** Faturayla birlikte, aynı veritabanı işleminde (transaction) bir "gönderilecekler" kaydı (outbox) yazılır.
Transaction ya ikisini birden yazar ya hiçbirini; "kaydedildi ama gönderilmesi unutuldu" durumu olamaz. Gönderimi ayrı
bir arka plan işçisi yapar: outbox'tan sırası gelenleri okur, ERP'ye gönderir, sonucu yazar. Servis çökse bile outbox
kaydı veritabanında durduğu için iş kaldığı yerden devam eder.

**Bedeli:**
- Gönderim artık "en az bir kez" (at-least-once) yapılır: işçi gönderip sonucu yazamadan çökerse aynı kayıt yeniden
  gönderilir. Bu yüzden alıcı tarafta (ya da gönderenin kendisinde) çift kayda karşı bir koruma gerekir; bizde bu 4.
  bölümde.
- Gönderim artık eşzamanlı değildir: API 202 döner, sonuç sonradan oluşur; durum listeleme endpoint'iyle izlenir.
- Outbox'tan kayıt almanın iki yaygın yolu var: tabloyu düzenli aralıklarla sorgulamak (polling) ya da veritabanı
  değişiklik akışını dinlemek (CDC, ör. Debezium). Biz polling kullandık: basit ve ek altyapı gerektirmiyor.

**Bizde nasıl:** `POST /api/v1/invoices` faturayı `Bekliyor` durumunda ve `erp_outbox` kaydını tek bir `SaveChanges`
ile (aynı transaction) yazıyor ve 202 dönüyor. Outbox kaydı yazılamazsa faturanın da yazılmadığı, outbox'a yazmayı
bilerek bozan bir testle gösterildi.

### 2) Exponential backoff ve jitter nedir, jitter neden gerekir

**Exponential backoff:** Başarısız bir isteği tekrar denerken her seferinde beklemeyi katlayarak artırmak (2, 4, 8,
16… sn). Sabit kısa aralıklarla denemek zaten zorlanan bir sistemi daha da yorar; katlanarak bekleme, sorun kısa
sürüyorsa hızlı toparlanmayı, uzun sürüyorsa yükü azaltmayı sağlar. Beklemenin sonsuz büyümemesi için bir tavan konur
(bizde 60 sn).

**Jitter:** Her beklemeye eklenen küçük rastgele bir sapma. **Neden gerekir:** Aynı anda başarısız olan çok sayıda
istek (ör. ERP kapalıyken gönderilen yüzlerce fatura) jitter olmadan hep tam aynı anlarda tekrar denenir (2. saniyede
hepsi, 4. saniyede hepsi…) ve ERP açıldığı anda tek bir dalga halinde üzerine yığılıp onu yeniden düşürebilir
("thundering herd"). Jitter bu denemeleri zamana yayar.

**Bizde nasıl:** 500, zaman aşımı ve ulaşılamama durumlarında bekleme 2^deneme sn; tavan 60 sn, üzerine 0–1 sn rastgele
jitter (tavanda taban 59 sn tutuluyor ki jitter eklenince bile 60'ı geçmesin). 429'da jitter yok: simülatörün
`Retry-After` başlığında söylediği süre kadar bekleniyor (saniye ya da tarih biçimi). Değerler ayar dosyasından okunuyor.

### 3) Eklenen kolonlar

`erp_outbox` tablosuna görevdeki 8 kolona ek olarak üç kolon eklendi:
- **`locked_until`:** Bir işçi kaydı aldığında "şu saate kadar bu kayıt benim" diye yazar (60 sn). **Neden gerekli:**
  Servis gönderim sırasında öldürülürse kaydın sonucu hiç yazılmaz; bu kolon olmasa kayıt ya sonsuza kadar "alınmış"
  kalır ya da hemen başka bir işçi tarafından alınıp hâlâ süren bir gönderimle çakışırdı. Süre dolunca kayıt güvenle
  yeniden alınabiliyor.
- **`locked_by`:** Kaydı hangi servis kopyasının aldığı. **Neden gerekli:** İki kopya çalışırken bir kaydın o an hangi
  kopyada olduğu ve hangi faturayı hangisinin gönderdiği bu kolondan görülebiliyor (madde 7'nin kanıtı).
- **`claim_token`:** Bir işçi kaydı her aldığında yazılan yeni, rastgele bir kimlik; sonuç yazılınca silinir.
  **Neden gerekli:** Sonuç yalnızca kayıt hâlâ bu kimliği taşıyorsa yazılıyor, fatura da yalnızca kayıt hâlâ bu
  kimlikle tutuluyorsa gönderiliyor. Böylece kilit süresi dolmuş eski bir iş (ör. donmuş bir süreç), kaydı ondan sonra
  alanın yerine ne gönderim yapabiliyor ne de onun sonucunun üzerine yazabiliyor. Son denemesi yarıda kalan kayıt aynı
  deneme numarasıyla yeniden alındığı için yalnızca deneme numarası bu ayrımı yapamıyordu.

### 4) Çift kayıt nasıl önlendi

Simülatör aynı faturayı her gelişinde yeniden kaydediyor; çift kaydı engellemek servisin işi. Fatura daha önce en az bir
kez gönderilmeye çalışıldıysa, servis tekrar göndermeden önce simülatöre `GET /api/v1/invoices/{numara}` ile "bu fatura
sende var mı?" diye soruyor. Varsa tekrar göndermiyor, simülatördeki referansı alıp faturayı Gönderildi yapıyor;
yalnızca simülatör açıkça "yok" (404) derse yeniden gönderiyor. Simülatöre sorulamazsa (kapalı, hata, zaman aşımı) hiç
göndermiyor, denemeyi başarısız sayıp daha sonra tekrar deniyor. Haklar bittiğinde de faturayı Başarısız yapmadan önce
simülatöre son kez soruyor; böylece son deneme simülatörde kaydedilip hata dönmüşse fatura yanlışlıkla Başarısız
kalmıyor.

### 5) Servis öldürüldüğünde faturalar neden kaybolmadı

- Kabul edilen her fatura önce veritabanına yazılıyor: POST, fatura ve outbox kaydı aynı transaction'da kaydedildikten
  sonra 202 dönüyor. Servis bu andan sonra ne zaman öldürülürse öldürülsün iş veritabanında duruyor.
- Gönderim sırasında öldürülürse kaydın kilidi (`locked_until`) 60 sn sonra doluyor ve kayıt yeniden alınıyor. Yarıda
  kalan denemede istek simülatöre ulaşmış olabileceği için servis önce simülatöre soruyor; oradaysa tekrar göndermiyor.
- Deneme sayısı gönderimden önce artırılıyor: yarıda kalan deneme de sayılıyor ve 10 deneme sınırı aşılmıyor.

### 6) İki kopya aynı kaydı neden aynı anda göndermedi

- İşçiler outbox'tan kaydı tek bir SQL cümlesiyle alıyor (`FOR UPDATE SKIP LOCKED`): iki kopya aynı anda sorgulasa bile
  birinin almakta olduğu satırı diğeri atlıyor; aynı satırı ikisi birden alamıyor.
- Aynı cümlede kayda `locked_until` ve `locked_by` yazılıyor; kayıt, işlem bittikten sonra da kilit süresi boyunca
  alınmış görünüyor ve diğer kopya onu almıyor.
- Sonuç yalnızca kayıt hâlâ o alımın kimliğini (`claim_token`) taşıyorsa yazılıyor; fatura da yalnızca kayıt hâlâ
  o kimlikle tutuluyorsa gönderiliyor.
- Her kopya yalnızca boş gönderim yeri kadar kayıt alıyor; gönderemeyeceği kayıtları kilitleyip diğerinden saklamıyor.

---

## Günler

| Tag | Gün | O günün hali |
|---|---|---|
| `gun-1` | ERP Simülatörü | [tree/gun-1](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-1) |
| `gun-2` | Fatura Servisi'nin ilk sürümü | [tree/gun-2](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-2) |
| `gun-3` | Güvenli Gönderim | [tree/gun-3](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-3) |
