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
- **Çift kayıt engellenmez:** aynı fatura numarası her gelişte yeni ERP referansıyla yeni kayıt açar.
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
  "RetryAfterFormat": "Seconds"
}
```

- Bu on değerin hepsi zorunludur; kodda varsayılan yoktur. Biri eksikse uygulama başlamaz ve hangisinin eksik olduğunu
  yazar (ör. `Simulator:Rates:Success is missing from the settings file`).
- Oranların toplamı tam 100 olmak zorundadır (her oran 0–100 arası bir sayı). Değilse uygulama açılmaz ve gelen toplamı
  yazar; örneğin diğerlerine dokunmadan yalnızca `Busy` 100 yapılırsa:
  `Simulator:Rates must add up to exactly 100 (was 185: Success=60 Busy=100 ServerError=10 SaveThenError=5 LateResponse=10).`
- `Success` 100, hata oranlarının hepsi 0 ise simülatör kusursuz bir ERP gibi davranır.
- Açılışta ayarlar loglanır: `Simulator settings: seed=42 success=60% busy=15% ... (total=100) ...`

Tek seferlik değişiklik ortam değişkeniyle de yapılabilir (toplam yine 100 olmalı):

```powershell
$env:Simulator__Rates__Success=0; $env:Simulator__Rates__Busy=100; $env:Simulator__Rates__ServerError=0; $env:Simulator__Rates__SaveThenError=0; $env:Simulator__Rates__LateResponse=0; docker compose up -d --force-recreate erp-simulator
```

---

## Fatura Servisi

.NET 10, ASP.NET Core Minimal API, kendi PostgreSQL veritabanı (`invoice-db`).

Şu anki sürüm **bilerek korumasızdır**: faturayı kaydeder, ERP Simülatörü'ne **bir kez** gönderir ve sonucu olduğu gibi
yazar. Tekrar deneme, bekleme ve çift gönderim koruması yoktur; `Retry-After` okunmaz.

### Veri

Tek tablo: `invoices` (`invoice_number`, `customer_code`, `amount`, `currency`, `invoice_date`, `status`,
`erp_reference`, `last_error`, `send_attempt_count`, `created_at`, `updated_at`).

- **Fatura numarasını servis üretir:** PostgreSQL sequence → `FTR-000001` (999999'dan sonra kısaltılmadan büyür).
  Gövdede gönderilen `invoiceNumber` yok sayılır.
- **`status`** yalnızca `Gönderildi` ya da `Başarısız` olabilir (veritabanında check constraint).
- `Gönderildi` → `erp_reference` dolu, `last_error` boş. `Başarısız` → `erp_reference` boş, `last_error` dolu.

### Endpoint'ler

| Endpoint | Davranış |
|---|---|
| `POST /api/v1/invoices` | Gövde: `customerCode`, `amount`, `currency`, `invoiceDate`. Fatura kaydedilir, aynı istekte simülatöre gönderilir. Simülatör `202` → `Gönderildi` + `erp_reference`; başka her sonuç (429, 500, 10 sn zaman aşımı, simülatöre ulaşılamaması) → `Başarısız` + `last_error`. Fatura her durumda oluştuğu için cevap `201`; sonuç gövdedeki `status`'ta. Geçersiz gövde `400`, hiçbir şey kaydedilmez. |
| `POST /api/v1/invoices/{faturaNumarası}/resend` | Yalnızca `Başarısız` fatura için: simülatöre bir kez daha gönderir, sonucu aynı şekilde yazar, `200`. `Gönderildi` ise `409`, yoksa `404`. |
| `GET /api/v1/invoices/{faturaNumarası}` | Faturanın servisteki hali (`200`) ya da `404`. |

Gönderim sırası: `send_attempt_count` veritabanında artırılır ve kayıt **ERP çağrısından önce** yazılır (`status` =
`Başarısız`, `last_error` = "Gönderim sürüyor"), sonra ERP cevabı yazılır. Böylece cevabı hiç gelmeyen bir gönderim de
sayılır. Aynı fatura aynı anda iki kez gönderilebilir (koruma yok); satır her zaman son gönderimin sonucunu taşır.

### Ayarlar

[`invoice-service/src/InvoiceService/appsettings.json`](invoice-service/src/InvoiceService/appsettings.json) → `Erp`:
`BaseUrl` (compose içinde `http://erp-simulator:8080`) ve `TimeoutSeconds: 10` (simülatöre yapılan isteğin zaman aşımı).
İkisi de zorunludur.

---

## Testler

| Ne | Komut |
|---|---|
| Unit testler | `dotnet test erp-simulator` ve `dotnet test invoice-service` |
| Elle testler — ERP Simülatörü | [`manual-tests/gun1/`](manual-tests/gun1/README.md) |
| Elle testler — Fatura Servisi | [`manual-tests/gun2/`](manual-tests/gun2/README.md) |
| Simülatör veritabanı / logları | `.\manual-tests\gun1\db.ps1`, `.\manual-tests\gun1\loglar.ps1` |
| Fatura Servisi veritabanı | `.\manual-tests\gun2\db.ps1` |
| Simülatör uçtan uca kontrol (bash) | `./scripts/erp-simulator-checklist.sh` |
| Simülatör dağılım ölçümü (bash) | `./scripts/erp-simulator-distribution.sh <adet>` |

Elle deneme: Swagger UI (yukarıdaki adresler) veya `.http` dosyaları
([simülatör](erp-simulator/src/ErpSimulator/ErpSimulator.http), [servis](invoice-service/src/InvoiceService/InvoiceService.http));
loglar için `docker compose logs -f erp-simulator` / `docker compose logs -f invoice-service`.
Script'ler engellenirse önce `Set-ExecutionPolicy -Scope Process Bypass`.

---

## Gün 2 — Fatura Servisi'nin ilk sürümü

Bugünün işi: simülatörde oranların yüzde olarak uygulanması (toplamı tam 100 değilse açılmaması) ve Fatura Servisi'nin
ilk, korumasız sürümü. Amaç, simülatör hata verdiğinde iki tarafta ne olduğunu sayılarla görmek.

### Zaman aşımı: neden 10 sn?

`HttpClient.Timeout` varsayılanı **100 saniyedir**. Bizim için uygun değil çünkü:

- `POST /api/v1/invoices` ERP cevabını aynı istekte bekliyor; simülatör geç cevapta 30 sn bekletiyor, takılan bir
  ERP'de ise çağıran taraf 100 sn bekler. Çoğu istemci, proxy ve gateway bundan önce vazgeçer: servis sonucu yazar
  ama çağıran hiç görmez.
- Beklenen her istek bir bağlantı, bir istek ve bir DB context'i açık tutar; ERP yavaşladığında bunlar birikir.
- 100 sn, "ERP yavaş" ile "ERP cevap vermiyor" arasında ayrım yapmaz; normal bir ERP cevabı milisaniyeler sürüyor.

Zaman aşımı "ERP kaydetmedi" demek değildir: simülatör geç cevapta faturayı **önce kaydedip sonra bekler**, bu yüzden
servis `Başarısız` yazarken fatura ERP'de kayıtlı olabilir.

### Kontrol listesi

| # | Madde | Script |
|---|---|---|
| 1 | Oranların toplamı 100 değilken simülatör açılmıyor, hata mesajında gelen toplam yazıyor | `.\manual-tests\gun2\1-oran-toplami.ps1` |
| 2 | Hata oranları 0 iken 100 fatura: serviste 100 Gönderildi, simülatörde 100 kayıt, `erp_reference` iki tarafta aynı | `.\manual-tests\gun2\2-hata-yok.ps1` |
| 3 | Varsayılan oranlar, seed 42, 100 fatura → karşılaştırma tablosu | `.\manual-tests\gun2\3-varsayilan.ps1` |
| 4 | 3'te Başarısız kalanları bir kez resend → tablo + simülatörde birden fazla kaydı olanlar | `.\manual-tests\gun2\4-yeniden-gonder.ps1` |
| 5 | Simülatör durdurulmuşken fatura oluşturma | `.\manual-tests\gun2\5-simulator-kapali.ps1` |
| 6 | Geç cevap %100: servis 10 sn'de Başarısız, fatura simülatörde kayıtlı | `.\manual-tests\gun2\6-gec-cevap.ps1` |

İki tarafı karşılaştıran script: `.\manual-tests\gun2\karsilastir.ps1` — servisteki her faturayı simülatörün GET
endpoint'iyle sorgular ve sayar. Ayrıntılar ve QA düzeltmelerinin ek testleri: [`manual-tests/gun2/`](manual-tests/gun2/README.md).

---

## Günler

| Tag | Gün | O günün hali |
|---|---|---|
| `gun-1` | ERP Simülatörü | [tree/gun-1](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-1) |
| `gun-2` | Fatura Servisi'nin ilk sürümü | [tree/gun-2](https://github.com/metinkaryagdi/Staj_Tasks/tree/gun-2) |
