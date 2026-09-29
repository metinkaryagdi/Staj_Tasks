# Staj_Tasks — Güvenilir ERP Fatura Entegrasyonu

Sipariş sisteminden kesilen faturaların güvenilmez bir ERP'ye **kaybolmadan** ve **iki kez işlenmeden** iletilmesi.

| Uygulama | Durum | Açıklama |
|---|---|---|
| `erp-simulator/` | ✅ Gün 1 | Muhasebe ERP'sini taklit eder, ayarlanan oranlarda bilerek hata üretir |
| `invoice-service/` | ⏳ | Faturayı kaydeder, ERP'ye gönderir, geri bildirimleri işler |

İki uygulama ayrı çalışır, yalnızca HTTP ile konuşur ve **her birinin kendi PostgreSQL veritabanı** vardır.

## Hızlı Başlangıç

```bash
docker compose up -d --build
```

| Servis | Adres |
|---|---|
| ERP Simülatörü | http://localhost:5080 |
| Swagger UI | http://localhost:5080/swagger |
| ERP veritabanı | `localhost:5433` (db/kullanıcı/şifre: `erp_simulator` / `erp` / `erp`) |

## ERP Simülatörü

### Endpoint'ler

**`POST /api/v1/invoices`**

```json
{
  "invoiceNumber": "INV-2026-0001",
  "customerCode": "C-001",
  "amount": 1250.50,
  "currency": "TRY",
  "invoiceDate": "2026-09-29"
}
```

Başarılı cevap `202 Accepted`:

```json
{ "erpReference": "ERP-00000001", "invoiceNumber": "INV-2026-0001", "receivedAt": "2026-09-29T07:00:00Z" }
```

Eksik/geçersiz alan → `400` (davranış seçilmeden reddedilir, seed dizisini kaydırmaz).

**`GET /api/v1/invoices/{invoiceNumber}`** → `200` + ERP referansı, kayıt yoksa `404`.
Simülatör çift kaydı engellemediği için bir fatura numarasının birden fazla kaydı olabilir;
`erpReference` ilk kaydı, `records` hepsini gösterir.

### Davranışlar

Her POST isteği için tek bir seed'li `Random`'dan bir davranış seçilir:

| Davranış | Varsayılan | Cevap | Kayıt |
|---|---|---|---|
| `Success` | %60 (kalan) | `202` + ERP referansı | Evet |
| `Busy` | %15 | `429` + `Retry-After: 5..30` | Hayır |
| `ServerError` | %10 | `500` | Hayır |
| `SaveThenError` | %5 | `500` | **Evet** |
| `LateResponse` | %10 | 30 sn bekleyip `202` | Evet (bekleme **öncesinde**) |

- **Çift kayıt engellenmez:** aynı fatura numarası tekrar gelirse yeni ERP referansıyla yeni kayıt açılır.
- **LateResponse:** kayıt beklemeden önce yazılır. İstemci timeout ile bağlantıyı kesse bile kayıt kalır — gerçek hayattaki "gönderdim ama cevap alamadım" durumu.
- **Retry-After:** RFC 9110'a göre iki biçimde gönderilebilir: saniye (`Retry-After: 17`) veya HTTP-date (`Retry-After: Tue, 29 Sep 2026 07:00:17 GMT`). Varsayılan saniyedir; `RetryAfterFormat: "HttpDate"` ile tarih biçimine geçilebilir.
- **Loglama:** her istek tek satırda loglanır:
  `ERP request #12 invoice=INV-2026-0001 behavior=Busy status=429 retryAfter=17s`

### Ayarlar

[`erp-simulator/src/ErpSimulator/appsettings.json`](erp-simulator/src/ErpSimulator/appsettings.json) (compose tarafından container'a mount edilir; değiştirip `docker compose restart erp-simulator` yeterli):

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

- Oranlar yüzdedir; `Success` = 100 − hata oranları toplamı. **Hepsi 0 → kusursuz ERP.**
- Toplam 100'ü aşarsa uygulama açılışta hata verir.
- Geçici değişiklik için ortam değişkeni de kullanılabilir:
  `Simulator__Rates__Busy=100 docker compose up -d --force-recreate erp-simulator`

**Determinizm:** her istek RNG'den sabit sayıda (2) değer çeker, bu yüzden davranış dizisi yalnızca seed'e ve isteklerin **geliş sırasına** bağlıdır. Sayaç süreç başına tutulur; aynı diziyi tekrar almak için simülatör yeniden başlatılır. Eşzamanlı isteklerde sıra, isteklerin simülatöre ulaşma sırasıdır.

### Testler

> **TODO (README son düzenleme):** "Nasıl test edilir?" bölümü mentor için adım adım yazılacak.
> Elle test için iki yol hazır:
> - **Swagger UI:** http://localhost:5080/swagger → endpoint'i aç → *Try it out* → *Execute*. Örnek gövde hazır gelir;
>   her *Execute* seed'li dizideki bir sonraki davranışı alır (202 / 429 + `Retry-After` / 500 / 30 sn gecikme).
> - **`.http` dosyası:** [`erp-simulator/src/ErpSimulator/ErpSimulator.http`](erp-simulator/src/ErpSimulator/ErpSimulator.http) —
>   Visual Studio, Rider veya VS Code (REST Client eklentisi) ile her isteğin üstündeki *Send Request*.
> - Seçilen davranışı canlı izlemek için: `docker compose logs -f erp-simulator`

```bash
# Unit testler (davranış seçici, oranlar, seed)
dotnet test erp-simulator

# Gün 1 kontrol listesi (uçtan uca, docker compose üzerinde, ~6 dk)
./scripts/erp-simulator-checklist.sh
```
