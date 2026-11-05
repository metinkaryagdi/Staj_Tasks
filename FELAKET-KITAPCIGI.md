# Felaket Kitapçığı: Fatura Servisi veritabanı kaybedildi

Yalnız Fatura Servisi veritabanı (`invoice-db`) kaybedildiğinde uygulanır. Kısa bir bağlantı kesintisinde
uygulanmaz: geri dönüş, son yedekten sonraki veriyi siler. ERP'nin kendi veritabanına dokunulmaz.

Komutlar repo kökünden çalıştırılır. Betik Git Bash ya da Linux kabuğunda çalışır.

## Operatörün sırası

1. **Kaybı doğrula.** Container ve veri duruyor mu bak:
   ```bash
   docker compose ps invoice-db
   ```
   ```bash
   docker compose logs --tail 50 invoice-db
   ```
   Veritabanı yalnızca durmuşsa önce `docker compose start invoice-db` denenir.
2. **Haber ver.** Sipariş sistemi sahibine fatura gönderiminin durduğunu, ERP/finans sorumlusuna geri dönüşün başladığını bildir.
3. **Servis logunu kaydet.** Kaybolan iptal isteklerinin ve faturaların numaraları başka hiçbir yerde kalmaz:
   ```bash
   docker compose logs --no-color invoice-service > kayip-oncesi-servis-logu.txt
   ```
   `invoice-service-2` açıksa aynı komutla onun logu da kaydedilir.
4. **Geri dön.** En yeni yedek kullanılır. `invoice-service-2` açıksa önce `docker compose stop invoice-service-2`, dönüş bitince yeniden başlatılır. Betik onay sormaz:
   ```bash
   scripts/restore-invoice-db.sh
   ```
5. **Kuyruğun erimesini bekle.** Şu sorgu 0 dönene kadar; servis bu sırada yeni fatura alır:
   ```bash
   docker compose exec -T invoice-db psql -U invoice -d invoice_service -tAc "SELECT count(*) FROM erp_outbox WHERE status = 'Bekliyor'"
   ```
6. **Mutabakatı başlat.** Kuyruk bitince, en az 2 dakika sonra ekrandan başlat. Son mutabakatı da son haberin üzerinden 60 dakika geçince başlat: serviste
   olmayan faturaların haberleri ancak o zaman `Tanınmayan Haber` olur.
7. **Bulguları ilgililere ver** (aşağıda). `Serviste Yok` kayıtları yalnızca karşılaştırma penceresinde görünür (`LookbackHours`, 24 saat), o süre geçmeden listeyi al.

## Kontrol edilecekler

| Ne | Nerede | Beklenen |
|---|---|---|
| Kullanılan yedeğin zamanı | Betiğin çıktısı, dosya adı (UTC) | Kayıp anından en çok 5 dakika + yedek süresi kadar önce alınmış olmalı. Daha eskiyse nedenine bak: `docker compose logs invoice-db-backup` |
| Son yedek bozuksa | `scripts/restore-invoice-db.sh invoice_<zaman>.dump` | Klasördeki bir önceki dosya verilir |
| Servis açıldı mı | Yeni fatura 202 alıyor | İlk kabul edilen faturanın numarası 1.000.000 ileri atlamıştır; bu beklenen davranıştır |
| ERP'de çift kayıt | Mutabakatın `ERP Çift Kayıt` bulgusu | Yok |
| Yedek servisi yeniden çalışıyor | `docker compose logs --tail 5 invoice-db-backup` | `yedek alindi` satırı |

## Kim elle müdahale eder

| Kim | Ne | Neye göre |
|---|---|---|
| **Operatör** | Kaybolan iptalleri ele alır | 3. adımdaki logda `Invoice cancellation queued` olup serviste iptal satırı olmayan faturalar. Fatura serviste varsa iptali yeniden ister; dönüşten sonra ERP'ye gitmiş olsa da iptal normal yoldan gider. Fatura `Serviste Yok` listesindeyse ERP/finans sorumlusuna, ikisinde de yoksa sipariş sistemi sahibine iletir: servis bu iptalleri kabul etmez |
| **Sipariş sistemi sahibi** | Kaybolan faturaları yeniden gönderir | Kendi aldığı numaralardan, serviste de `Serviste Yok` listesinde de olmayanlar. **`Serviste Yok` listesindekiler yeniden gönderilmez:** ERP'de zaten vardır, aynı fatura ikinci numarayla girer. Operatörün ilettiği, iptal istenmiş faturalar da yeniden gönderilmez |
| **ERP/finans sorumlusu** | `Serviste Yok` kayıtlarını inceler | Bulgunun ayrıntısı referansı, tutarı ve varsa "ERP'de iptal edilmiş" bilgisini yazar. Bu kayıtlar servise kendiliğinden geri gelmez. Operatörün ilettiği iptalleri ERP'de karşılar |
