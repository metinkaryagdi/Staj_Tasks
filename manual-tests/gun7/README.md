# Gün 7 — Operasyon ekranındaki eksikler: kontrol listesi

Önce `docker compose up -d --build` (ekran http://localhost:5100, Fatura Servisi http://localhost:5090).
Script'ler repo kök klasöründen çalıştırılır. Hepsi sonunda `SONUÇ: GEÇTİ` ya da `KALDI` yazar; her kontrolde veritabanı
çıktısı ve beklenen / gelen değer görünür.

| # | Madde | Nasıl |
|---|---|---|
| 1 | Takılı süzgeci: listedeki faturalar ve sayı = özetteki takılı sayısı = veritabanı | `.\manual-tests\gun7\adim1-takili.ps1` |
| 2 | Özetteki takılı kartına tıklayınca liste Takılı süzgeciyle açılıyor | ekranda, aşağıya bakın |
| 3 | Karar geciktirilince "ERP Karar Vermedi" raporlanıyor ve ekranda görünüyor; karar gelince sonraki çalışma düzeltiyor | `.\manual-tests\gun7\adim3-karar-yok.ps1`; sonra script'in yazdığı fatura detayı ve mutabakat çalışması |
| 4 | Ekran ilk açılışta adı soruyor, yenileyince sormuyor | ekranda, aşağıya bakın |
| 5 | Tekli, toplu yeniden gönderme ve mutabakat başlatma operator_actions'a doğru ad ve sonuçla; toplu gönderimde fatura başına kayıt | `.\manual-tests\gun7\adim2-operator.ps1` (B, C, D) |
| 6 | X-Operator-Name olmadan bu üç istek 400 | `.\manual-tests\gun7\adim2-operator.ps1` (A) |
| 7 | ERP'nin hiç almadığı 50 eski Başarısız fatura: ilk çalışma 50 sorgu, ikinci 0 (loglarla) | `.\manual-tests\gun7\adim4-gereksiz-sorgu.ps1` |
| 8 | 120 mutabakat çalışması varken liste sayfa sayfa doğru | `.\manual-tests\gun7\adim5-calisma-sayfalari.ps1` |

Script'li maddeleri art arda çalıştırmak için: `.\manual-tests\gun7\kontrol-listesi.ps1`. Ek olarak `ek-zamanlayici.ps1`
zamanlanmış çalışmanın başlatanının "Zamanlayıcı" yazıldığını gösterir (servis 1 dk aralıkla yeniden başlatılır);
`ek-elle-takip.ps1` takılı faturanın elle takibe alınmasını ve kapatılmasını sınar (ikisi de kontrol listesinde "Ek").
7. maddenin süresi için iki script daha var, kontrol listesine dahil değiller: `ek-24-saat-siniri.ps1` "Kayıt yok" cevabı
23 sa 59 dk önce alınmış faturanın sorulmadığını, 24 saat dolunca sorulduğunu gösterir (~1,5 dk); `ek-sorgu-ayari.ps1`
servisi `NotFoundRecheckHours=1` ile yeniden başlatıp sürenin ayardan okunduğunu gösterir, sonda ayar dosyasındaki değere
döner (~3 dk).

## Ekrandan elle yapılan maddeler

**2) Takılı kartı.** Özet sayfasındaki **Takılı fatura** kartına tıklayın: Fatura Listesi açılır, Durum seçiminde **Takılı**
seçilidir, adres `/faturalar?durum=Takılı`, listenin altındaki fatura sayısı karttaki sayıyla aynıdır.

**4) Ad.** Tarayıcının bu sitedeki verisini silin (ya da üst çubuktaki **Değiştir**'e basın) ve http://localhost:5100'ü açın:
sayfalar yerine "Adınız" formu gelir. Bir ad yazıp **Devam et**'e basın; üst çubukta "Kullanıcı: <ad>" görünür. Sayfayı
yenileyin (F5): ad yeniden sorulmaz. Ardından bir faturayı yeniden gönderin; fatura detayının **Müdahaleler** bölümünde ad görünür.
