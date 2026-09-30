# Elle test — Gün 2 kontrol listesi (Fatura Servisi)

Repo kök klasöründe PowerShell açın, önce stack'i kaldırın:

```powershell
docker compose up -d --build
```

Script'ler engellenirse: `Set-ExecutionPolicy -Scope Process Bypass`.

| # | Madde | Komut | Süre |
|---|---|---|---|
| 1 | Oran toplamı 100 değil → simülatör açılmaz, hata mesajında toplam yazar | `.\manual-tests\gun2\1-oran-toplami.ps1` | ~15 sn |
| 2 | Hata oranları 0 → 100 fatura: serviste 100 Gönderildi, simülatörde 100 kayıt, referanslar aynı | `.\manual-tests\gun2\2-hata-yok.ps1` | ~20 sn |
| 3 | Varsayılan oranlar, seed 42, 100 fatura → karşılaştırma tablosu | `.\manual-tests\gun2\3-varsayilan.ps1` | ~2 dk |
| 4 | 3'te Başarısız kalanlar bir kez resend → tablo + birden fazla kaydı olanlar | `.\manual-tests\gun2\4-yeniden-gonder.ps1` | ~1 dk |
| 5 | Simülatör durdurulmuşken fatura oluştur | `.\manual-tests\gun2\5-simulator-kapali.ps1` | ~15 sn |
| 6 | Geç cevap %100 → servis 10 sn'de Başarısız, fatura simülatörde kayıtlı | `.\manual-tests\gun2\6-gec-cevap.ps1` | ~45 sn |

3 ve 4 sırayla çalıştırılmalı: 3 fatura aralığını `manual-tests\output\gun2-3.json`'a yazar, 4 aynı aralığı kullanır
ve simülatörü yeniden başlatmaz (seed 42 dizisi kaldığı yerden devam eder). 3 simülatörü yeniden oluşturduğu için
dizi her çalıştırmada baştan başlar; sonuçlar her seferinde aynı çıkar.

Her script simülatörü gerekirse kendi ayarlarıyla yeniden başlatır ve sonunda `appsettings.json` ayarlarına döndürür.

2-6. maddeler Gün 1'deki gibi bir **VERİTABANI KONTROLÜ** bölümüyle biter: önce Fatura Servisi'nin (`invoice-db`), sonra
simülatörün (`erp-db`) tablosu gösterilir; çalıştırılan SQL, gelen tablo ve beklenen/gelen karşılaştırması yazılır.
İki veritabanı ayrı olduğu için tek sorguda birleştirilemez; karşılaştırma script tarafında yapılır. 3 ve 4'te karşılaştırma
tablosu bir kez de doğrudan iki veritabanından hesaplanır ve simülatörün GET endpoint'iyle bulunan sonuçla aynı olmalıdır.
`SONUÇ` satırı HTTP sonucuyla veritabanı sonucunu birleştirir.

## Karşılaştırma script'i

```powershell
.\manual-tests\gun2\karsilastir.ps1                                  # servisteki bütün faturalar
.\manual-tests\gun2\karsilastir.ps1 -From FTR-000101 -To FTR-000200  # yalnızca bu aralık
.\manual-tests\gun2\karsilastir.ps1 -Details                         # her fatura tek tek
```

Fatura listesini ve durumlarını servisin veritabanından (`invoice-db`) okur, her faturayı simülatörün
`GET /api/v1/invoices/{faturaNumarası}` endpoint'iyle sorgular ve şunları sayar:

- Serviste Gönderildi, simülatörde var
- Serviste Başarısız, simülatörde yok
- Serviste Başarısız, simülatörde var
- Serviste Gönderildi, simülatörde yok (olmaması gerekir)
- Simülatörde birden fazla kaydı olan
- Serviste Gönderildi olanların `erp_reference` değeri simülatördeki kayıtlardan biriyle aynı mı

## Veritabanı

| | Fatura Servisi | ERP Simülatörü |
|---|---|---|
| Host / port | `localhost:5434` | `localhost:5433` |
| Veritabanı | `invoice_service` | `erp_simulator` |
| Kullanıcı / şifre | `invoice` / `invoice` | `erp` / `erp` |

```powershell
.\manual-tests\gun2\db.ps1                                              # Fatura Servisi, etkileşimli psql (\q ile çıkılır)
.\manual-tests\gun2\db.ps1 -Sql "SELECT status, count(*) FROM invoices GROUP BY status;"
.\manual-tests\gun1\db.ps1                                              # ERP Simülatörü
```

## Loglar

```powershell
docker compose logs -f invoice-service
```

Her gönderim için bir satır:

```
ERP send invoice=FTR-000141 attempt=1 result=Başarısız http=- erpReference=- elapsed=10015ms error=ERP 10 saniye içinde cevap vermedi (zaman aşımı).
```
