# ERP Sürüm Geçişi: v1'den v2'ye

Fatura Servisi durdurulmaz. Hangi faturanın hangi sürümü kullanacağını veritabanındaki yüzde ayarı belirler; fatura numarasının
hash'i yüzdenin altındaysa v2, değilse v1 kullanılır. Bir değişiklik bütün kopyalarda bir sonraki ERP isteğinden itibaren geçerlidir.

Komutlar repo kökünden Git Bash ya da Linux kabuğunda çalışır. `TOKEN`, `fatura-operatoru` rolüne sahip bir kullanıcının token'ıdır.

## Yüzdeyi değiştirme

```bash
curl -X PUT http://localhost:5090/api/v1/erp-version -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"v2Percent":10}'
```

## Her adımda kontrol

Bir sonraki adıma, aşağıdakilerin hepsi temizse geçilir. Biri temiz değilse geri dönülür.

1. **Sürüm dağılımı.** Yüzde değiştikten bir dakika sonra bakılır: yoldaki istekler o sırada biter. Son dakikada ERP'ye giren kayıtlar yüzdeye yakın olmalı:
   ```bash
   docker compose exec -T erp-db psql -U erp -d erp_simulator -c "SELECT api_version, count(*) FROM invoices WHERE received_at > now() - interval '1 minute' GROUP BY 1"
   ```
2. **Başarısız ve kuyruk.** Kuyruk erimeye devam etmeli. Faturası iptal edilmiş ya da reddedilmiş satırlar dışında Başarısız olmamalı, ikinci sorgu 0 satır dönmeli:
   ```bash
   docker compose exec -T invoice-db psql -U invoice -d invoice_service -c "SELECT kind, status, count(*) FROM erp_outbox GROUP BY 1, 2 ORDER BY 1, 2"
   ```
   ```bash
   docker compose exec -T invoice-db psql -U invoice -d invoice_service -c "SELECT left(last_error, 80), count(*) FROM erp_outbox WHERE status = 'Başarısız' AND last_error NOT LIKE 'Fatura iptal edildi%' AND last_error NOT LIKE '%Invoice rejected%' GROUP BY 1"
   ```
3. **ERP'de çift.** 0 satır dönmeli:
   ```bash
   docker compose exec -T erp-db psql -U erp -d erp_simulator -c "SELECT invoice_number, count(*) FROM invoices GROUP BY 1 HAVING count(*) > 1"
   ```
4. **Mutabakat.** Operasyon ekranının Mutabakat sayfasından çalıştırılır. `ERP Çift Kayıt`, `Alan Farkı`, `Serviste Yok`, `ERP Kaydı Yok` ve `Cevap Alınamadı` olmamalı.

## Adımlar

| # | İş | Ek kontrol |
|---|---|---|
| 1 | Önce ERP'nin yeni sürümü, sonra servisin yeni sürümü kurulur. Yüzde 0 kalır. | `curl http://localhost:5080/api/v2/invoices/YOK` 404 ve `Invoice not found` döner. `curl http://localhost:5090/api/v1/erp-version -H "Authorization: Bearer $TOKEN"` 0 döner. |
| 2 | Yüzde 10 | Dağılımda v2 görünür. |
| 3 | Yüzde 50 | Dağılım yaklaşık yarı yarıyadır. |
| 4 | Yüzde 100 | Son dakikada v1 kaydı yoktur. |
| 5 | Eski sürüm kapatılır (aşağıda). | Kuyruk erir, kontrol 2 temiz kalır, mutabakat `Tamamlandı` biter. |

## Eski sürümü kapatma

Yüzde 100'de, kontroller temizken yapılır. Simülatör birkaç saniye kapanır; servis bekleyen işleri tekrar dener.

```bash
Simulator__V1Enabled=false docker compose up -d erp-simulator
```

Kapalıyken v1 her isteği 410 ile reddeder. Servis 410 alan isteği aynı denemede v2 ile yapar, fatura ya da iptal bu yüzden Başarısız olmaz.
Kuyrukta bekleyen işlerin kapatmayı beklemesi gerekmez. Kalıcı olması için `Simulator__V1Enabled=false` `.env` dosyasına da yazılır.

## Geri dönüş

Yukarıdaki kontrollerden biri temiz değilse:

```bash
curl -X PUT http://localhost:5090/api/v1/erp-version -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"v2Percent":0}'
```

Eski sürüm kapatıldıysa önce yeniden açılır:

```bash
Simulator__V1Enabled=true docker compose up -d erp-simulator
```

Sonra şunlar kontrol edilir:

- Yüzde değiştikten bir dakika sonra, son dakikada ERP'ye yeni v2 kaydı girmiyor (kontrol 1).
- ERP'de çift yok (kontrol 3).
- Mutabakat temiz (kontrol 4).

v2 ile alınmış faturalar ERP'de kalır; sorgu ve iptalleri v1 ile yapılır, haberleri yeni biçimde gelmeye devam eder ve servis ikisini de kabul eder.

## Bilinmesi gerekenler

- **Çift kayıt:** v1 mükerreri önlemez. v1 kullanılan adımlarda çift kayıt görülürse kontrol 3 ve mutabakat bulur; fatura numarası ERP/finans ile incelenir.
- **Yedekten dönüş:** Felaket kitapçığı uygulanırsa yüzde, yedekteki değere döner. Dönüşten sonra `GET /api/v1/erp-version` ile bakılır.
