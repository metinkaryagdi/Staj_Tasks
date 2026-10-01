# Elle test — Gün 3 kontrol listesi (Güvenli Gönderim)

Repo kök klasöründe PowerShell açın, önce stack'i kaldırın:

```powershell
docker compose up -d --build
```

Script'ler engellenirse: `Set-ExecutionPolicy -Scope Process Bypass`.

| # | Madde | Komut |
|---|---|---|
| 1 | Hata oranları 0 → 100 fatura: hepsi Gönderildi, simülatörde her faturadan tam bir kayıt, `erp_reference` iki tarafta aynı | _yazılacak_ |
| 2 | Varsayılan oranlar → 1000 fatura, kuyruk boşalana kadar bekle → sonuç tablosu, boşalma süresi, fatura başına ortalama deneme | _yazılacak_ |
| 3 | Busy %100 → 5 fatura, 1 dk sonra Success %100: her denemeden önce beklenen süre = Retry-After (saniye ve tarih biçimi) | _yazılacak_ |
| 4 | ServerError %100 → 1 fatura: bekleme katlanarak artıyor, 60 sn'yi geçmiyor, 10. denemede Başarısız; sonra Success %100 + resend → Gönderildi | _yazılacak_ |
| 5 | Simülatör durdurulmuş → 50 fatura (hepsi 202), 2 dk sonra simülatörü başlat → 50'si Gönderildi, çift kayıt yok | _yazılacak_ |
| 6 | Varsayılan oranlar, 200 fatura gönderilirken servisi 3 kez `docker kill` + yeniden başlat → kayıp ve çift kayıt 0 | _yazılacak_ |
| 7 | Servisin iki kopyası aynı veritabanında, varsayılan oranlar, 500 fatura → çift kayıt 0 | _yazılacak_ |

## Adım testleri

Gün 3 adım adım yapılıyor; her adımın kendi testi var (kontrol listesinin parçası değil):

| Adım | Ne kontrol ediliyor | Komut |
|---|---|---|
| 1 | Şema: `invoices.status` üç değer, `erp_outbox` 10 kolon (8 istenen + `locked_until`, `locked_by`), kısıtlar gerçekten çalışıyor | `.\manual-tests\gun3\adim1-sema.ps1` |
| 2 | `POST` fatura (Bekliyor) + `erp_outbox` kaydını aynı transaction'da yazıyor, `202` dönüyor, simülatöre gitmiyor; outbox yazılamazsa fatura da yazılmıyor | `.\manual-tests\gun3\adim2-outbox-yazma.ps1` |
| 3 | Arka plan worker'ı kuyruğu boşaltıyor (şimdilik tek deneme): Success %100'de 20 fatura Gönderildi/Tamamlandı, referanslar aynı; LateResponse %100'de 25 fatura → simülatöre aynı anda en fazla 10 istek (10 + 10 + 5 dalga) | `.\manual-tests\gun3\adim3-worker.ps1` |
| 4 | Tekrar deneme: 429'dan sonra tam Retry-After kadar bekleniyor (saniye ve tarih biçimi); 500'de 2/4/8/16/32/59 sn + 0–1 sn jitter, hiçbiri 60'ı geçmiyor; 10. deneme de başarısızsa fatura ve outbox Başarısız (~8 dk) | `.\manual-tests\gun3\adim4-tekrar-deneme.ps1` |
| 5 | Çift kayıt koruması: daha önce gönderilmeye çalışılmış fatura için POST'tan önce simülatöre GET ile soruluyor. SaveThenError ve LateResponse'ta 2. denemede `found`, POST yok; simülatör kapalıyken `unknown`, POST yok; açılınca `notFound` → POST. Varsayılan oranlarla 100 fatura: çift kayıt 0, kayıp 0 (~4 dk) | `.\manual-tests\gun3\adim5-cift-kayit.ps1` |
| 6 | `GET /api/v1/invoices?status=…` veritabanıyla aynı sayıları dönüyor, geçersiz durum 400; resend: olmayan 404, Başarısız olmayan 409; resend simülatöre gitmiyor, kuyruğa alıyor (202): simülatörde kayıtlıysa `found` (POST yok), değilse `notFound` → POST; outbox kaydı olmayan Gün 2 faturası da kuyruğa alınıyor; aynı anda iki resend → 202 + 409 (~1 dk) | `.\manual-tests\gun3\adim6-endpointler.ps1` |
