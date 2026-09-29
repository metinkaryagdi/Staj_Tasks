# Staj_Tasks

| Uygulama | Klasör | Durum |
|---|---|---|
| ERP Simülatörü | `erp-simulator/` | Gün 1 tamamlandı |
| Fatura Servisi | `invoice-service/` | Başlanmadı |

## Kurulum

```bash
docker compose up -d --build
```

| Servis | Adres |
|---|---|
| ERP Simülatörü | http://localhost:5080 |
| Swagger UI | http://localhost:5080/swagger |
| ERP veritabanı | `localhost:5433` — db `erp_simulator`, kullanıcı `erp`, şifre `erp` |

---

## Gün 1 — ERP Simülatörü

### Kurulum gereksinimleri

| İstenen | Karşılığı |
|---|---|
| Public GitHub reposu, iki uygulama için | Bu repo; `erp-simulator/` eklendi, `invoice-service/` sonraki günlerde |
| .NET ile yazılacak | .NET 10, ASP.NET Core Minimal API |
| Kendi PostgreSQL veritabanı | `erp-db` container'ı (PostgreSQL 17), Fatura Servisi ayrı veritabanı kullanacak |
| Tek komutla ayağa kalkma | `docker compose up -d --build` — veritabanı hazır olunca simülatör başlar, tablo migration ile otomatik oluşur |

### Endpoint'ler

| İstenen | Karşılığı |
|---|---|
| `POST /api/v1/invoices` — fatura no, müşteri kodu, tutar, para birimi, fatura tarihi | Gövde: `invoiceNumber`, `customerCode`, `amount`, `currency`, `invoiceDate`. Başarılı cevap `202` + `erpReference` (ör. `ERP-00000001`). Eksik/geçersiz alan `400`. |
| `GET /api/v1/invoices/{faturaNumarası}` — kayıt var mı, ERP referansı; yoksa `404` | `200` + `registered`, `erpReference`, `recordCount`, `records[]`. Kayıt yoksa `404`. |

Örnek istek:

```json
POST /api/v1/invoices
{ "invoiceNumber": "INV-2026-0001", "customerCode": "C-001", "amount": 1250.50, "currency": "TRY", "invoiceDate": "2026-09-29" }

202 Accepted
{ "erpReference": "ERP-00000001", "invoiceNumber": "INV-2026-0001", "receivedAt": "2026-09-29T07:00:00+00:00" }
```

### Simülatörün davranışı

Her POST için aşağıdaki davranışlardan biri seed'li rastgele seçimle seçilir:

| Davranış | Oran | Cevap | Fatura kaydedilir mi |
|---|---|---|---|
| `Success` | %60 | `202` + ERP referansı | Evet |
| `Busy` | %15 | `429` + `Retry-After` (5–30 sn) | Hayır |
| `ServerError` | %10 | `500` | Hayır |
| `SaveThenError` | %5 | `500` | Evet |
| `LateResponse` | %10 | 30 sn bekleyip `202` | Evet |

| # | İstenen | Karşılığı |
|---|---|---|
| 1 | Retry-After 5–30 sn arası rastgele; biçimleri araştırılacak | Her 429'da 5–30 arası değer. RFC 9110'a göre iki biçim var: saniye `Retry-After: 17` (varsayılan) veya HTTP-date `Retry-After: Tue, 29 Sep 2026 07:00:17 GMT`. `RetryAfterFormat` ayarı ile seçilir, ikisi de denendi. |
| 2 | Çift kayıt engellenmeyecek | Aynı fatura numarası her gelişte yeni ERP referansıyla yeni kayıt açar (`invoice_number` unique değil). |
| 3 | Oranların hepsi ve geç cevap süresi ayar dosyasından; hata oranları 0 ise kusursuz ERP | `appsettings.json` → `Simulator` bölümü: beş oranın hepsi (`Success` dahil) ve `LateResponseDelaySeconds`. Oranlar toplamlarına bölünerek uygulanır; hata oranlarının hepsi 0 ise her istek `Success` olur. Kodda varsayılan değer yoktur: dosyada bir ayar eksikse uygulama açılmaz. |
| 4 | Ayar dosyasında seed; aynı seed aynı davranış dizisi | `Simulator:Seed`. Aynı seed + aynı istek sırası = aynı davranış dizisi (simülatör yeniden başlayınca dizi baştan başlar). |
| 5 | Her istek seçilen davranışla loglanır | `ERP request #12 invoice=INV-2026-0001 behavior=Busy status=429 retryAfter=17s` |

#### Ayarlar

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

Bu on değerin hepsi zorunludur; biri eksikse uygulama başlamaz ve hangisinin eksik olduğunu yazar
(ör. `Simulator:Rates:Success is missing from the settings file`). Açılışta etkin oranlar loglanır:
`Simulator settings: seed=42 success=60% busy=15% serverError=10% saveThenError=5% lateResponse=10% (configured total=100) ...`

Tek seferlik değişiklik ortam değişkeniyle de yapılabilir:
`Simulator__Rates__Busy=100 docker compose up -d --force-recreate erp-simulator`

---

## Test verisi — kontrol listesi

Yedi madde iki yoldan çalıştırıldı ve ikisinde de geçti:

- **Otomatik:** `./scripts/erp-simulator-checklist.sh` (bash, docker compose üzerinde uçtan uca)
- **Elle:** [`manual-tests/`](manual-tests/README.md) altındaki PowerShell script'leri. Her script önce testin kendi çıktısını, ardından **veritabanı kontrolünü** (SQL, gelen tablo, beklenen/gelen) verir.

Her senaryo simülatörü kendi oranlarıyla yeniden başlatır. Tablodaki değerler elle test çalıştırmasından.

| # | İstenen | Script | Sonuç (HTTP) | Veritabanı | Durum |
|---|---|---|---|---|---|
| 1 | Hata oranları 0 iken 100 fatura: 100 başarılı, 100 kayıt | `1-hata-yok.ps1` | 202: 100/100 | 100 kayıt, hepsi Success, 100 farklı referans | Geçti |
| 2 | Meşgul %100: hepsi 429 + Retry-After, kayıt yok | `2-mesgul.ps1` | 429: 20/20, Retry-After `8 18 11 18 24 11 13 11 5 20 8 23 19 23 28 18 6 20 5 25` | 0 kayıt | Geçti |
| 3 | Kaydedip hata %100: hepsi 500, hepsi veritabanında | `3-kaydet-hata.ps1` | 500: 20/20 | 20 kayıt, hepsi SaveThenError | Geçti |
| 4 | Geç cevap %100: 30 sn sonra cevap, veritabanında | `4-gec-cevap.ps1` | 202: 2/2, 30,21 sn / 30,04 sn | 2 kayıt, LateResponse | Geçti |
| 5 | Aynı fatura no ile 2 istek: farklı referanslı 2 kayıt | `5-cift-kayit.ps1` | 202, 202 | `ERP-00001935`, `ERP-00001936` | Geçti |
| 6 | Varsayılan oranlar, aynı seed, 50 fatura × 2: loglardaki dizi aynı | `6-seed.ps1` | Loglarda 50/50 aynı (Success 35, Busy 9, ServerError 4, LateResponse 2) | A ve B'de aynı istekler aynı davranışla kayıtlı | Geçti |
| 7 | GET kayıtlı → referans, olmayan → 404 | `7-sorgu.ps1` | 200 (`ERP-00002011`) / 404 | Veritabanındaki referans GET ile aynı | Geçti |

Senaryo 6 davranış dizisi (iki çalıştırmada aynı):

```
Busy Success Success Busy Success Success Success Success Success ServerError Success Success ServerError Success Success Busy Success Success ServerError Success Busy Success Success Busy Success Success Success Busy Success Busy Success Success Success Success Success Success Success ServerError Success Busy LateResponse Success Busy Success Success Success Success Success Success LateResponse
```

### Nasıl çalıştırılır

```powershell
.\manual-tests\1-hata-yok.ps1
```

Diğerleri: `2-mesgul.ps1`, `3-kaydet-hata.ps1`, `4-gec-cevap.ps1`, `5-cift-kayit.ps1`, `6-seed.ps1`, `7-sorgu.ps1`.
Script'ler engellenirse önce `Set-ExecutionPolicy -Scope Process Bypass`. Parametreler ve ayrıntılar: [`manual-tests/README.md`](manual-tests/README.md).

| Yardımcı | Kullanım |
|---|---|
| `.\manual-tests\db.ps1` | Veritabanını açar (`psql`, çıkmak için `\q`). Tek sorgu: `-Sql "SELECT ..."` |
| `.\manual-tests\loglar.ps1` | Simülatör loglarını canlı izler; `-Tail 50` son 50 satır |

```bash
./scripts/erp-simulator-checklist.sh
```

---

## Ek doğrulamalar

### Dağılım ve tutarlılık

Amaç: simülatörün istenen oranları gerçekten karşıladığını ve sonuçların tutarlı olduğunu göstermek.
`./scripts/erp-simulator-distribution.sh <adet>` ile ölçüldü — varsayılan oranlar, seed 42, geç cevap süresi 0 sn
(yalnızca ölçüm süresini kısaltmak için). Davranışlar HTTP üzerinden gönderilen isteklerin loglarından sayıldı.

**Oranlar**

| Davranış | Hedef | 22.000 istek | 1.000.000 istek | Adet (1.000.000) |
|---|---|---|---|---|
| Success | %60 | %59,84 | %60,01 | 600.086 |
| Busy | %15 | %14,83 | %15,04 | 150.392 |
| ServerError | %10 | %10,36 | %10,02 | 100.206 |
| LateResponse | %10 | %9,96 | %9,95 | 99.466 |
| SaveThenError | %5 | %5,01 | %4,99 | 49.850 |
| Ki-kare (kritik değer 9,49) | | 3,40 | 4,76 | |

Her iki ölçümde de gözlenen dağılım hedefle uyumlu. Örnek büyüdükçe sapma küçülüyor: 22.000 istekte en büyük sapma 0,36 puan, 1.000.000 istekte 0,05 puan.

**Bağımsızlık** — bir önceki davranışa göre bir sonraki davranışın dağılımı (1.000.000 istek):

| Önceki \ Sonraki | Success | Busy | ServerError | SaveThenError | LateResponse |
|---|---|---|---|---|---|
| Success | %60,0 | %15,1 | %10,1 | %5,0 | %10,0 |
| Busy | %60,0 | %15,1 | %10,0 | %5,0 | %9,9 |
| ServerError | %60,1 | %14,9 | %10,1 | %5,0 | %9,9 |
| SaveThenError | %60,0 | %14,9 | %10,0 | %5,0 | %10,1 |
| LateResponse | %60,3 | %15,1 | %9,8 | %4,9 | %9,9 |
| **Hedef** | %60 | %15 | %10 | %5 | %10 |

Her satır hedef dağılımda: önceki davranış bir sonrakini etkilemiyor.

**Tutarlılık** — loglardan sayılan sonuçlar üç bağımsız kaynakla karşılaştırıldı (1.000.000 istek):

| Kaynak | Sonuç | Durum |
|---|---|---|
| Gönderilen / loglanan istek | 1.000.000 / 1.000.000 | Kayıp yok |
| HTTP durum kodları | 202 = 699.552 (Success + LateResponse), 429 = 150.392 (Busy), 500 = 150.056 (ServerError + SaveThenError) | Loglarla aynı |
| Veritabanı | Success 600.086, LateResponse 99.466, SaveThenError 49.850; Busy ve ServerError 0 | Loglarla aynı |
| Seçim kodunun HTTP'siz çalıştırılması, seed 42 ([`erp-simulator-replay.cs`](scripts/erp-simulator-replay.cs)) | Beş davranışın adetleri | Birebir aynı |

22.000 isteklik ölçümde ayrıca kayıt açan 16.459 isteğin her biri, HTTP'siz çalıştırmadaki aynı sıra numaralı kararla tek tek eşleştirildi.
Script bu karşılaştırmayı artık her çalıştırmada karar karar yapıyor (`Cross-check seed`).

Dağılım ölçümü (1.000.000 istek yaklaşık 32 dk sürer; daha kısa bir kontrol için adet küçültülebilir):

```bash
./scripts/erp-simulator-distribution.sh 1000000
```

### Seed

İlk 12 istek:

| Çalıştırma | Davranış dizisi |
|---|---|
| seed 42 | Busy Success Success Busy Success Success Success Success Success ServerError Success Success |
| seed 42 (tekrar) | Busy Success Success Busy Success Success Success Success Success ServerError Success Success |
| seed 7 | Success Busy Success Success ServerError Success Success SaveThenError ServerError SaveThenError Busy Success |

Aynı seed aynı diziyi, farklı seed farklı diziyi üretiyor.

### Unit testler

`dotnet test erp-simulator`: 23/23 geçti (seed, oranlar, Retry-After aralığı, ayar doğrulama).

---

## Elle deneme

| Yöntem | Kullanım |
|---|---|
| Swagger UI | http://localhost:5080/swagger → endpoint → Try it out → Execute. Örnek gövde hazır gelir. |
| `.http` dosyası | [`erp-simulator/src/ErpSimulator/ErpSimulator.http`](erp-simulator/src/ErpSimulator/ErpSimulator.http) — Visual Studio, Rider veya VS Code (REST Client) ile Send Request. |
| Loglar | `docker compose logs -f erp-simulator` — her isteğin seçilen davranışı |

Her POST seed'li dizideki bir sonraki davranışı alır; aynı istek art arda 202, 429 veya 500 dönebilir.
