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

### Davranışlar

| Davranış | Oran | Cevap | Fatura kaydedilir mi |
|---|---|---|---|
| `Success` | %60 | `202` + ERP referansı | Evet |
| `Busy` | %15 | `429` + `Retry-After` (5–30 sn) | Hayır |
| `ServerError` | %10 | `500` | Hayır |
| `SaveThenError` | %5 | `500` | Evet |
| `LateResponse` | %10 | 30 sn bekleyip `202` | Evet |

| İstenen | Karşılığı |
|---|---|
| Retry-After 5–30 sn arası rastgele | Her 429'da 5–30 arası değer. Başlık iki biçimde gönderilebilir (RFC 9110): saniye `Retry-After: 17` (varsayılan) veya HTTP-date `Retry-After: Tue, 29 Sep 2026 07:00:17 GMT` — `RetryAfterFormat` ayarı ile seçilir. |
| Çift kayıt engellenmeyecek | Aynı fatura numarası her gelişte yeni ERP referansıyla yeni kayıt açar. |
| Oranlar ve geç cevap süresi ayar dosyasından | `appsettings.json` → `Simulator` bölümü. `Success` = 100 − hata oranları; hata oranları 0 ise kusursuz ERP. |
| Seed ile tekrarlanabilir seçim | `Simulator:Seed`. Aynı seed + aynı istek sırası = aynı davranış dizisi. |
| Her istek seçilen davranışla loglanır | `ERP request #12 invoice=INV-2026-0001 behavior=Busy status=429 retryAfter=17s` |

### Ayarlar

[`erp-simulator/src/ErpSimulator/appsettings.json`](erp-simulator/src/ErpSimulator/appsettings.json) — container'a mount edilir, değişiklikten sonra `docker compose restart erp-simulator`.

```json
"Simulator": {
  "Seed": 42,
  "Rates": { "Busy": 15, "ServerError": 10, "SaveThenError": 5, "LateResponse": 10 },
  "LateResponseDelaySeconds": 30,
  "RetryAfterMinSeconds": 5,
  "RetryAfterMaxSeconds": 30,
  "RetryAfterFormat": "Seconds"
}
```

Tek seferlik değişiklik ortam değişkeniyle de yapılabilir:
`Simulator__Rates__Busy=100 docker compose up -d --force-recreate erp-simulator`

---

## Sonuçlar

### Kontrol listesi

`./scripts/erp-simulator-checklist.sh` ile docker compose üzerinde uçtan uca çalıştırıldı. Her senaryo simülatörü kendi oranlarıyla yeniden başlatır.

| # | Senaryo | Beklenen | Sonuç | Durum |
|---|---|---|---|---|
| 1 | Hata oranları 0, 100 fatura | 100 başarılı, DB'de 100 kayıt | 202: 100/100, DB: 100 kayıt | Geçti |
| 2 | Meşgul %100 | Hepsi 429 + Retry-After, DB'de kayıt yok | 429: 20/20, Retry-After değerleri `8 18 11 18 24 11 13 11 5 20 8 23 19 23 28 18 6 20 5 25`, DB: 0 kayıt | Geçti |
| 3 | Kaydedip hata %100 | Hepsi 500, hepsi DB'de | 500: 20/20, DB: 20 kayıt | Geçti |
| 4 | Geç cevap %100 | 30 sn sonra 202, DB'de | 202: 2/2, süreler 30,16 sn / 30,07 sn, DB: 2 kayıt | Geçti |
| 5 | Aynı fatura no ile 2 istek | Farklı referanslı 2 kayıt | 202, 202 → `ERP-00000123`, `ERP-00000124` | Geçti |
| 6 | Varsayılan oranlar, aynı seed, 50 fatura × 2 | Davranış dizileri birebir aynı | 50/50 aynı (Success 35, Busy 9, ServerError 4, LateResponse 2) | Geçti |
| 7 | GET kayıtlı / kayıtsız | Referans döner / 404 | 200 (`ERP-00000001`) / 404 | Geçti |

Senaryo 6 davranış dizisi (iki çalıştırmada aynı):

```
Busy Success Success Busy Success Success Success Success Success ServerError Success Success ServerError Success Success Busy Success Success ServerError Success Busy Success Success Busy Success Success Success Busy Success Busy Success Success Success Success Success Success Success ServerError Success Busy LateResponse Success Busy Success Success Success Success Success Success LateResponse
```

### Oranlar tutuyor mu

`./scripts/erp-simulator-distribution.sh 22000` — varsayılan oranlar, seed 42, geç cevap süresi 0 sn (yalnızca ölçüm süresini kısaltmak için). 22.000 istek gönderildi, davranışlar loglardan sayıldı. Aynı seed ile tekrar çalıştırıldığında aynı sayılar çıkar.

| Davranış | Hedef | Gözlenen | Adet |
|---|---|---|---|
| Success | %60 | %59,84 | 13.165 |
| Busy | %15 | %14,83 | 3.262 |
| ServerError | %10 | %10,36 | 2.279 |
| LateResponse | %10 | %9,96 | 2.192 |
| SaveThenError | %5 | %5,01 | 1.102 |

Ki-kare uyum testi: 3,40 (serbestlik derecesi 4, %5 kritik değer 9,49) — gözlenen dağılım hedefle uyumlu.

Ölçümün doğruluğu üç bağımsız kaynakla kontrol edildi:

| Kaynak | Sonuç | Durum |
|---|---|---|
| HTTP durum kodları | 202 = 15.357 (Success + LateResponse), 429 = 3.262 (Busy), 500 = 3.381 (ServerError + SaveThenError) | Loglarla aynı |
| Veritabanı | Success 13.165, LateResponse 2.192, SaveThenError 1.102; Busy ve ServerError 0 | Loglarla aynı |
| Seçim kodunun HTTP'siz çalıştırılması (seed 42) | Aynı 22.000 davranış; kayıt açan 16.459 isteğin tamamı DB'deki sıra numarasıyla eşleşti | Birebir aynı |

### Seçim rastgele mi

Bir önceki davranışa göre bir sonraki davranışın dağılımı (22.000 istek):

| Önceki \ Sonraki | Success | Busy | ServerError | SaveThenError | LateResponse |
|---|---|---|---|---|---|
| Success | %59,9 | %14,8 | %10,6 | %4,9 | %9,8 |
| Busy | %59,6 | %15,1 | %9,6 | %5,2 | %10,5 |
| ServerError | %60,2 | %14,7 | %10,0 | %5,2 | %10,0 |
| SaveThenError | %59,7 | %14,8 | %9,9 | %4,5 | %11,2 |
| LateResponse | %59,4 | %14,8 | %10,8 | %5,4 | %9,6 |
| **Hedef** | %60 | %15 | %10 | %5 | %10 |

Her satır hedef dağılıma yakın: önceki davranış bir sonrakini etkilemiyor.

### Seed

İlk 12 istek:

| Çalıştırma | Davranış dizisi |
|---|---|
| seed 42 | Busy Success Success Busy Success Success Success Success Success ServerError Success Success |
| seed 42 (tekrar) | Busy Success Success Busy Success Success Success Success Success ServerError Success Success |
| seed 7 | Success Busy Success Success ServerError Success Success SaveThenError ServerError SaveThenError Busy Success |

Aynı seed aynı diziyi, farklı seed farklı diziyi üretiyor.

### Unit testler

`dotnet test erp-simulator` — 10/10 geçti.

| Test | Kontrol |
|---|---|
| Aynı seed | 500 çekilişte aynı dizi |
| Farklı seed | Farklı dizi |
| Hata oranları 0 | 1000 çekilişin tamamı Success |
| Tek hata türü %100 (4 test) | Yalnızca o davranış seçiliyor |
| Varsayılan oranlar | 100.000 çekilişte her oran hedefin ±1 puan içinde |
| Retry-After aralığı | En küçük 5, en büyük 30 |
| Geçersiz ayar | Hata oranları toplamı 100'ü aşınca uygulama açılmıyor |

---

## Elle test

| Yöntem | Kullanım |
|---|---|
| Swagger UI | http://localhost:5080/swagger → endpoint → Try it out → Execute. Örnek gövde hazır gelir. |
| `.http` dosyası | [`erp-simulator/src/ErpSimulator/ErpSimulator.http`](erp-simulator/src/ErpSimulator/ErpSimulator.http) — Visual Studio, Rider veya VS Code (REST Client) ile Send Request. |
| Loglar | `docker compose logs -f erp-simulator` — her isteğin seçilen davranışı |

Her POST seed'li dizideki bir sonraki davranışı alır; aynı istek art arda 202, 429 veya 500 dönebilir.

```bash
dotnet test erp-simulator
```
```bash
./scripts/erp-simulator-checklist.sh
```
```bash
./scripts/erp-simulator-distribution.sh 22000
```
