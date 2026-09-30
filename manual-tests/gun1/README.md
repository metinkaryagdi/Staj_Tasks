# Elle test — Gün 1 kontrol listesi

Her madde için ayrı bir PowerShell script'i var. Script:

1. Simülatörü o testin ayarlarıyla yeniden başlatır.
2. İstekleri gönderip her cevabı ekrana yazar.
3. **VERİTABANI KONTROLÜ** bölümünde çalıştırdığı SQL'i, veritabanından gelen tabloyu ve beklenen/gelen karşılaştırmasını gösterir.
4. En sonda HTTP ve veritabanı sonucunu birleştirip `SONUÇ: GEÇTİ / KALDI` basar.
5. Simülatörü `appsettings.json` ayarlarıyla tekrar başlatır.

Veritabanına ayrıca girmeye gerek yoktur.

## Hazırlık (bir kez)

Repo kök klasöründe PowerShell açın:

```powershell
docker compose up -d --build
```

Script'ler engellenirse (execution policy), sadece bu PowerShell penceresi için izin verin:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

## Testler

| # | Madde | Komut | Süre |
|---|---|---|---|
| 1 | Hata oranları 0 → 100 fatura, 100 başarılı, 100 kayıt | `.\manual-tests\gun1\1-hata-yok.ps1` | ~15 sn |
| 2 | Meşgul %100 → hepsi 429 + Retry-After, 0 kayıt | `.\manual-tests\gun1\2-mesgul.ps1` | ~10 sn |
| 3 | Kaydedip hata %100 → hepsi 500, hepsi veritabanında | `.\manual-tests\gun1\3-kaydet-hata.ps1` | ~10 sn |
| 4 | Geç cevap %100 → 30 sn sonra 202, veritabanında | `.\manual-tests\gun1\4-gec-cevap.ps1` | ~1 dk |
| 5 | Aynı fatura no ile 2 istek → farklı referanslı 2 kayıt | `.\manual-tests\gun1\5-cift-kayit.ps1` | ~10 sn |
| 6 | Varsayılan oranlar, aynı seed, 50 fatura × 2 → loglardaki dizi aynı | `.\manual-tests\gun1\6-seed.ps1` | ~2-3 dk |
| 7 | GET kayıtlı → referans, olmayan → 404 | `.\manual-tests\gun1\7-sorgu.ps1` | ~10 sn |

Parametreler:

```powershell
.\manual-tests\gun1\1-hata-yok.ps1 -Count 100          # gönderilecek fatura sayısı (2, 3, 4, 6 için de geçerli)
.\manual-tests\gun1\2-mesgul.ps1 -HttpDate             # Retry-After'ı saniye yerine HTTP-date biçiminde gönderir
.\manual-tests\gun1\7-sorgu.ps1 -InvoiceNumber T1-20260929-130000-1   # var olan bir faturayı sorgular
```

Her script fatura numaralarına test numarası ve saat ekler (ör. `T1-20260929-131500-7`), bu yüzden testler
veritabanını temizlemeden art arda çalıştırılabilir.

6. testte iki çalıştırmanın log satırları `manual-tests\output\` altına kaydedilir.

## Veritabanını açmak

```powershell
.\manual-tests\gun1\db.ps1
```

Etkileşimli `psql` oturumu açar (çıkmak için `\q`). Açılırken faydalı sorgular listelenir. Tek sorgu için:

```powershell
.\manual-tests\gun1\db.ps1 -Sql "SELECT behavior, count(*) FROM invoices GROUP BY behavior;"
```

Görsel bir araçla (DBeaver, pgAdmin, DataGrip, VS Code PostgreSQL eklentisi) bağlanmak için:

| Alan | Değer |
|---|---|
| Host | `localhost` |
| Port | `5433` |
| Veritabanı | `erp_simulator` |
| Kullanıcı / şifre | `erp` / `erp` |
| Tablo | `invoices` |

## Logları izlemek

```powershell
.\manual-tests\gun1\loglar.ps1            # canlı takip, Ctrl+C ile çıkılır
.\manual-tests\gun1\loglar.ps1 -Tail 50   # son 50 satır
```

Her POST için şuna benzer bir satır düşer:

```
ERP request #12 invoice=T6-...-12 behavior=Busy status=429 retryAfter=17s
```

## Elle tek istek

Swagger UI: http://localhost:5080/swagger. PowerShell'den tek istek:

```powershell
Invoke-RestMethod -Method Post -Uri http://localhost:5080/api/v1/invoices -ContentType 'application/json' `
  -Body '{"invoiceNumber":"INV-1","customerCode":"C-001","amount":1250.50,"currency":"TRY","invoiceDate":"2026-09-29"}'
Invoke-RestMethod http://localhost:5080/api/v1/invoices/INV-1
```

Varsayılan oranlarda POST bazen 429 veya 500 döner; `Invoke-RestMethod` bu durumda kırmızı hata basar, bu beklenen davranıştır.

Oranları kalıcı değiştirmek için `erp-simulator/src/ErpSimulator/appsettings.json` → `Simulator` bölümünü düzenleyip
`docker compose restart erp-simulator` çalıştırın.
