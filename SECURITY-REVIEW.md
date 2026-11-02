# Güvenlik Gözden Geçirmesi

Repodaki her şey kapsamdadır: Fatura Servisi, ERP Simülatörü, operasyon ekranı, Keycloak ayarları (`keycloak/`), docker compose
ve izleme bileşenleri (`monitoring/`, alert-receiver); ayrıca Dockerfile'lar, CI (`.github/`), yük testi ve script'ler.
Bulgular [OWASP Top 10:2025](https://top10.owasp.org/2025/) kategorileriyle eşleştirilmiştir.

## Yöntem

- **Saldırgan:** repodaki compose olduğu gibi çalıştırılmışken (1) aynı ağdaki herhangi bir makine, (2) repoyu okuyabilen
  biri. Repo GitHub'da public olduğu için (2) internetteki herkestir. Derece açığın kendisine ve düzeltmeden önceki duruma
  göre verilmiştir: port kapatıldıktan ya da düzeltildikten sonraki durum dereceyi değiştirmez, aynı türden açıklar aynı
  derecededir. Bütün bulgular bu ölçütle yeniden gözden geçirildi; değişenler "Derece değişiklikleri"nde.
- **Önem derecesi:** saldırganın açığı ne kadar kolay kullandığı ve etkisi:
  - **Kritik:** kimlik bilgisi gerekmeden ya da herkesin bildiği bilgiyle sistemin tamamı (kimlik sağlayıcı, veri) ya da bir
    bileşen ele geçer (yönetici hesabıyla ya da kimlik doğrulaması olmayan bütün API'siyle).
  - **Yüksek:** faturaların durumu, verisi ya da yetkiler değiştirilebilir ya da doğrudan okunabilir.
  - **Orta:** etki sınırlı ya da başka bir açığın yanında anlam kazanır.
  - **Düşük:** bilgi sızıntısı, yalnız geliştirmede etkili olan ya da istismarı zor durumlar.
- **Kod incelemesi:** iki servisin, alert-receiver'ın ve operasyon ekranının bütün kaynak kodu (`.cs`, `.ts`, `.tsx`; bin, obj,
  node_modules ve migration'lar hariç 162 dosya, 10.636 satır), ayar dosyaları, realm dosyası, compose, Dockerfile'lar, nginx ve izleme ayarları, CI, git geçmişi.
- **Canlı kontroller** (`manual-tests/gun20/`):
  - `1-canli-tarama.ps1`: portlara bilgisayarın yerel ağ adresinden bağlanır (bu adresten açılan bir port aynı ağdaki başka
    makineden de açılır), repodaki şifrelerle giriş dener, kimliksiz uçları ve sahte webhook'u dener, HTTP başlıklarını,
    CORS'u ve hata cevaplarını kontrol eder. Düzeltmeden önce ve sonra koşulmuştur; sonraki koşuya, eski değerlerin
    aynı bilgisayardan da reddedildiğini gösteren B2 bölümü eklenmiştir.
  - `2-log-arama.ps1`: isteklerden sonraki loglarda ve şu anki container'ların açılışından bu yana bütün loglarda token, şifre
    ve secret arar (gönderilen log seviyeleriyle ve `-AyrintiliLog` ile).
  - `3-ham-sql.ps1`: üretim kodunda ham SQL kullanılan her yeri bulur; EF logunda görülenleri logdan, görülmeyenleri koddan gösterir.
  - Keycloak yönetim API'sinden realm ayarlarının okunması, izleme araçlarına kimliksiz ve başka origin'den istekler; yan
    kontroller (Jaeger izleri, Keycloak discovery CORS'u, `text/plain` POST, ekran kodu) `manual-tests/output/gun20/b-ek-kontroller.txt`'de.
- **Kapatılan Orta bulguların kontrolleri** (`manual-tests/gun21/`, çıktılar `manual-tests/output/gun21/`):
  `1-once-sonra.ps1` her kapatılan bulgunun istismar isteğini gönderir; düzeltmelerden önce (`b-once.txt`) ve sonra
  (`c-sonra.txt`) koşulmuştur. İz bırakmaz: geçici kullanıcılar silinir, `DROP TABLE` `ROLLBACK` ile geri alınır, alarm susturma
  kaydı silinir. `2-yuk-testi.ps1` düzeltmelerden sonraki yük testidir (`c-yuk-testi.txt`).
- **Bağımlılık taraması:** `dotnet list package --vulnerable --include-transitive`, `npm audit`.
- **Bağımsız kontrol:** bulgular iki ayrı gözden geçirmeyle (biri dokümanı denetleyen, biri dokümanı okumadan bulgu arayan)
  karşılaştırıldı; bir bulgunun derecesi (Y5) ayrıca tarafsız bir değerlendirmeyle belirlendi. Gün 21'de dereceler,
  kapatılan bulgular ve kanıtları iki ayrı bağımsız denetimle (biri bütün iddiaları, biri izleme girişinin oturum davranışını
  kaynak koddan ve canlıda sınayan) kontrol edildi; bulgularına göre düzeltildi.

## Özet

Bulgu numarasındaki harf önem derecesinin ilk verildiği halin baş harfidir (K Kritik, Y Yüksek, O Orta, D Düşük), rakam o
derecedeki sırasıdır. Derecesi sonradan değişen bulgunun numarası, önceki raporlardaki atıflar kopmasın diye aynı kalır.

| # | Önem | Bulgu | OWASP | Durum |
|---|---|---|---|---|
| K1 | Kritik | Keycloak yönetici hesabı `admin/admin`, Keycloak portu ağa açık | A07, A02 | Düzeltildi |
| K2 | Kritik | Veritabanı şifreleri repoda, veritabanı portları ağa açık | A07, A02 | Düzeltildi |
| Y1 | Yüksek | compose'daki bütün portlar bütün ağ arayüzlerine açık | A02 | Düzeltildi |
| Y2 | Yüksek | Webhook HMAC secret'ı repoda: sahte ERP haberiyle fatura durumu değiştirilebiliyor | A04, A08 | Düzeltildi |
| Y3 | Yüksek | Sipariş sistemi client secret'ı repoda: fatura oluşturma yetkili token alınabiliyor | A07 | Düzeltildi |
| Y4 | Yüksek | Test kullanıcılarının şifreleri repoda: operatör yetkisi alınabiliyor | A07 | Düzeltildi |
| Y5 | Kritik (önce Yüksek) | ERP Simülatörü'nün API'si kimlik doğrulaması istemiyor | A01, A06 | Kısmen: ağ erişimi kapatıldı; uygulamada kimlik doğrulaması yok, öneri |
| O1 | Orta | Kaba kuvvet koruması ve şifre politikası yok; `admin-cli` şifreyle token veriyor | A07 | Düzeltildi (kaba kuvvet, şifre politikası); `admin-cli` öneri |
| O2 | Kritik (önce Orta) | Grafana yönetici hesabı imajın varsayılanı (`admin/admin`) | A07 | Düzeltildi |
| O3 | Kritik (önce Orta) | Alertmanager, Prometheus ve Jaeger kimlik doğrulaması istemiyor | A01 | Düzeltildi |
| O4 | Orta | Operasyon ekranında HTTP güvenlik başlıkları yok, nginx sürümü görünüyor | A02 | Düzeltildi (ekran); API'nin `Server` başlığı öneri |
| O5 | Orta | Bütün trafik HTTP üzerinden (TLS yok) | A04 | Öneri |
| O6 | Orta | ERP'deki kayıt içeriği karşılaştırılmadan faturaya bağlanıyor | A06 | Öneri |
| O7 | Orta | Tarayıcı client'ı offline token alabiliyor; refresh token tekrar kullanılabiliyor | A07 | Düzeltildi (ekranın client'ı, refresh token); varsayılan roldeki `offline_access` öneri |
| O8 | Orta | Güvenlik olayları saklanmıyor ve izlenmiyor | A09 | Öneri |
| O9 | Orta | Uygulamaların veritabanı kullanıcıları süper kullanıcı | A02 | Düzeltildi |
| O10 | Orta | Alertmanager ve Prometheus her web sitesine CORS izni veriyor | A01 | Düzeltildi |
| D1 | Düşük | Geliştirme bağımlılığında (vitest) bilinen açıklar | A03 | Öneri |
| D2 | Düşük | ERP Simülatörü'nün 409 cevabı mevcut ERP referansını söylüyor | A01 | Öneri |
| D3 | Düşük | Uygulama container'ları root olarak çalışıyor | A02 | Öneri |
| D4 | Düşük | Keycloak yönetim konsolu kullanıcı giriş adresiyle aynı yerde | A02 | Öneri |
| D5 | Düşük | İmaj ve GitHub Actions sürümleri sabit değil; workflow yetkisi sınırsız | A03 | Öneri |
| D6 | Düşük | Fatura Servisi'nde hız sınırı yok | A02 | Öneri |
| D7 | Düşük | Çalışan Keycloak'ta şifreyle token veren test client'ı açık | A07 | Öneri |
| D8 | Düşük | İmzası doğrulanmamış webhook başlığı loga olduğu gibi yazılıyor | A05, A09 | Öneri |
| D9 | Düşük | ERP cevaplarına üst sınır yok | A06, A10 | Öneri |
| D10 | Düşük | ERP Simülatörü'nün para birimi kuralı sondaki satır sonunu kabul ediyor | A05 | Öneri |
| D11 | Düşük | Collector'lar compose ağında kimliksiz veri kabul ediyor | A08 | Öneri |

### Derece değişiklikleri

| # | Eski | Yeni | Neden |
|---|---|---|---|
| O2 | Orta | Kritik | K1 ile aynı türden açık: düzeltmeden önce ağa açık bir yönetim arayüzü, herkesin bildiği `admin/admin` yönetici hesabıyla. Grafana yöneticisi panoları değiştirir, veri kaynağı ekleyerek Grafana'nın ulaştığı başka sistemlere istek attırır; düzeltmesi K1'deki gibi tek satır. Önceki derece port kapatıldıktan sonraki duruma göre verilmişti. |
| O3 | Orta | Kritik | O2 ve K1 ile aynı türden: düzeltmeden önce ağa açık yönetim arayüzleri, üstelik hiç kimlik bilgisi istemeden. Alertmanager'da alarmlar susturulur (bileşenin yönetimi; tanımdaki "kimlik bilgisi gerekmeden bir bileşen ele geçer"), Jaeger'dan fatura numaraları ve ERP referansları okunur (ERP referansı Y2'deki sahte haberin ön koşulu). Önceki derece içeriğin okunmadığına bakılarak verilmişti. |
| Y5 | Yüksek; kalan risk Orta | Kritik | O3 ile aynı türden: ağa açık, hiç kimlik bilgisi istemeyen bir servis. Saldırgan bütün faturaların müşteri kodunu, tutarını ve ERP referansını okur, kayıt açıp faturanın hangi ERP kaydına bağlı olduğunu değiştirir (O6), mutabakatı bozar; O3'tekinden fazlası. Derece düzeltmeden sonra kalan riske göre de verilmez: açığın kendisi kapanmadı, yalnız ona ağdan ulaşılması kapandı; durum "Kısmen". |

Kritik tanımı bu gözden geçirmede genişletildi. Gün 20'de "sistemin tamamı ele geçer" idi; aynı türden açıkların aynı derecede
olması için "ya da bir bileşen ele geçer (yönetici hesabıyla ya da kimlik doğrulaması olmayan bütün API'siyle)" eklendi:
herkesin bildiği yönetici şifresi (K1, O2) ve kimlik doğrulaması olmayan servis (O3, Y5). Diğer bulguların derecesi aynı
kaldı. Gözden geçirmede ayrıca ölçülenler: O3'te Jaeger'dan kimliksiz istekle fatura numaraları ve
ERP referansları okunuyor, tutar ve müşteri izlerde yok (`manual-tests/gun21/0-jaeger-fatura-verisi.ps1`,
`a0-jaeger-fatura-verisi.txt`: 20 faturanın numarası, 5 ERP referansı). O10'da Prometheus'tan okunan metrikler toplam sayılar
(etiketleri `result`, `status`, `type`), fatura verisi yok. O10 Orta kaldı: istismar için kurbanın, yığın çalışırken saldırganın
sayfasını kendi tarayıcısında açması gerekiyor (O3'te ağdaki biri doğrudan istek atıyordu).

## Bulgular

### K1 — Keycloak yönetici hesabı `admin/admin`, Keycloak portu ağa açık (Kritik, düzeltildi)

- **Ne:** Keycloak'ın yönetici hesabı herkesin bildiği `admin/admin` ile kuruluyordu ve Keycloak bütün ağ arayüzlerinden
  dinliyordu (`start-dev`; `sslRequired: external` yerel ağ adreslerinden HTTP girişine izin veriyor).
- **Nerede:** `docker-compose.yml` (`KC_BOOTSTRAP_ADMIN_PASSWORD`, `ports`).
- **Nasıl istismar edilir:** Aynı ağdaki biri `master` realm'inden `admin-cli` ile `admin/admin` kullanarak token alır;
  yönetim API'siyle kendine operatör rolü olan bir kullanıcı açar ya da imza anahtarlarını değiştirir.
- **Etki:** Kimlik sağlayıcının tamamı ele geçer; Fatura Servisi bu Keycloak'ın imzaladığı her token'a güvendiği için bütün
  roller saldırganın olur.
- **Öneri:** Yönetici şifresi repoda değil ortamdan gelsin, yoksa Keycloak açılmasın; port yalnız bu bilgisayara açılsın.
- **Düzeltme:** Şifre `.env`'deki `KEYCLOAK_ADMIN_PASSWORD`'den (`.env` git'e girmez, örneği `.env.example`); değer yoksa
  compose açılmıyor. Port yalnız `127.0.0.1`'de (Y1).
- **Önce:** istek `POST http://<yerel ağ adresi>:8080/realms/master/protocol/openid-connect/token`
  (`grant_type=password`, `client_id=admin-cli`, `admin/admin`) → 200, yönetici token'ı (`1-canli-tarama.ps1` B, `b-canli-once.txt`).
- **Sonra:** aynı istek → bağlantı kurulamıyor (B, HTTP 0); aynı istek `localhost:8080`'e → 400 `invalid_grant` (B2)
  (`c-canli-sonra.txt`).

### K2 — Veritabanı şifreleri repoda, veritabanı portları ağa açık (Kritik, düzeltildi)

- **Ne:** İki PostgreSQL'in kullanıcı adı ve şifresi aynıydı (`invoice/invoice`, `erp/erp`), repodaydı ve portları ağa açıktı.
- **Nerede:** `docker-compose.yml` (`POSTGRES_PASSWORD`), iki servisin `appsettings.json` ve `appsettings.Docker.json`
  bağlantı dizeleri.
- **Nasıl istismar edilir:** `psql postgresql://invoice:invoice@<adres>:5434/invoice_service`.
- **Etki:** Bütün veri API'nin yetki kuralları atlanarak okunur ve yazılır; faturaların durumu, tutarı, operatör
  müdahalelerinin kaydı (`operator_actions`) değiştirilir ya da silinir. Kullanıcılar ayrıca süper kullanıcı (O9).
- **Öneri:** Şifreler repoda değil ortamdan gelsin; veritabanı portları yalnız bu bilgisayara açılsın.
- **Düzeltme:** Şifreler `.env`'den (`ERP_DB_PASSWORD`, `INVOICE_DB_PASSWORD`); compose bağlantı dizelerini ortam
  değişkeniyle veriyor, ayar dosyalarında şifre yok. Portlar yalnız `127.0.0.1`'de. `.env`'den önce oluşturulmuş bir volume
  eski şifreyi tutar; bir kez `ALTER USER` ile değiştirilir (README, Kurulum).
- **Önce:** istek `psql postgresql://invoice:invoice@<yerel ağ adresi>:5434/invoice_service` → giriş yapıldı
  (`1-canli-tarama.ps1` B, `b-canli-once.txt`).
- **Sonra:** aynı adrese bağlantı kurulamıyor (B); `psql` ile iki veritabanına eski şifreyle (`invoice/invoice`, `erp/erp`) giriş
  → `password authentication failed` (B2) (`c-canli-sonra.txt`). Test:
  `ShippedSettingsTests.Shipped_settings_hold_no_secret_or_password`, gönderilen ayar dosyasının bağlantı dizesinde şifre yok.

### Y1 — compose'daki bütün portlar bütün ağ arayüzlerine açık (Yüksek, düzeltildi)

- **Ne:** Yayımlanan 10 port (`iki-kopya` profilindeki 5091 ile 11) `"PORT:PORT"` biçimindeydi; Docker bunları bütün arayüzlere bağlıyor: veritabanları (5433, 5434),
  ERP Simülatörü (5080), Fatura Servisi (5090), operasyon ekranı (5100), Keycloak (8080), Jaeger (16686), Prometheus (9090),
  Alertmanager (9093), Grafana (3000).
- **Nerede:** `docker-compose.yml`, her servisin `ports:` satırı.
- **Nasıl istismar edilir:** Aynı ağdaki biri bilgisayarın adresine bağlanır; K1, K2, Y5, O2, O3 bu erişimle doğrudan kullanılır.
- **Etki:** Yalnız geliştiricinin bilgisayarında kalması gereken veritabanları, kimlik sağlayıcı ve yönetim araçları ağa açılır;
  ERP Simülatörü'nden fatura verisi doğrudan okunur.
- **Öneri:** Portlar yalnız bu bilgisayara açılsın.
- **Düzeltme:** Bütün portlar (5091 dahil) `"127.0.0.1:PORT:PORT"`.
- **Önce:** istek: varsayılan profildeki 10 porta yerel ağ adresinden TCP bağlantısı → 10'u açık (`1-canli-tarama.ps1` A,
  `b-canli-once.txt`).
- **Sonra:** aynı bağlantılar → 10'u kapalı (`c-canli-sonra.txt`). `iki-kopya` profilindeki 5091 denenmedi; compose satırı
  aynı biçimde değişti. Port daraltması ağ erişimini kapatır, uygulamaların kendi kimlik doğrulaması eksikliğini kapatmaz (Y5, O3, O10).

### Y2 — Webhook HMAC secret'ı repoda: sahte ERP haberiyle fatura durumu değiştirilebiliyor (Yüksek, düzeltildi)

- **Ne:** ERP haberlerinin imza anahtarı iki servisin ayar dosyasında düz metin olarak duruyordu. İmza doğrulaması doğru (bkz.
  "Webhook imzası"), ama anahtar repoyu okuyan herkesin elindeydi.
- **Nerede:** `invoice-service/.../appsettings.json` (`ErpWebhooks:Secret`), `erp-simulator/.../appsettings.json` (`Webhooks:Secret`).
- **Nasıl istismar edilir:** Haber, faturanın ERP referansıyla eşleşmezse yok sayılıyor; referans ERP Simülatörü'nden token'sız
  okunuyor (Y5). Saldırgan referansı alır, `invoice.rejected` haberini repodaki secret'la imzalar, `POST /api/v1/erp-webhooks`'a gönderir.
- **Etki:** ERP'nin vermediği bir karar faturaya yazılır; kesin durum bir daha değişmediği için ERP'nin gerçek kararı yok sayılır.
- **Öneri:** Secret repoda değil ortamdan gelsin; ayar dosyasında değer olmasın, değer yoksa servis açılmasın.
- **Düzeltme:** Secret `.env`'deki `ERP_WEBHOOK_SECRET`'tan; iki ayar dosyasında değer boş, boşsa servis açılmıyor.
- **Önce:** istek `POST /api/v1/erp-webhooks`, FTR-000001 için repodaki secret'la imzalanmış `invoice.rejected` → 200, fatura
  Gönderildi → Reddedildi (`1-canli-tarama.ps1` D, `b-canli-once.txt`).
- **Sonra:** aynı istek FTR-000007 için → 401, fatura Gönderildi kaldı (`c-canli-sonra.txt`). Not: fatura durumunu dışarıdan
  değiştirmenin secret gerektirmeyen bir yolu ERP Simülatörü üzerinden açık (Y5, O6).

### Y3 — Sipariş sistemi client secret'ı repoda (Yüksek, düzeltildi)

- **Ne:** `siparis-sistemi` client'ının secret'ı realm dosyasındaydı; realm her açılışta bu dosyadan kuruluyor.
- **Nerede:** `keycloak/fatura-realm.json`.
- **Nasıl istismar edilir:** Keycloak'a ulaşabilen ve repoyu okuyan biri `client_credentials` ile token alır.
- **Etki:** `fatura-olusturucu` rolüyle istediği kadar fatura oluşturur; bunlar ERP'ye gönderilir.
- **Öneri:** Secret realm dosyasında olmasın, realm içe aktarılırken ortamdan verilsin.
- **Düzeltme:** Realm dosyasında `"secret": "${ORDER_SYSTEM_CLIENT_SECRET}"`; Keycloak içe aktarırken ortamdan okuyor, compose
  `.env`'deki değeri veriyor. Testlerin Keycloak'ı kendi test değerini veriyor.
- **Önce:** istek `POST http://<yerel ağ adresi>:8080/realms/fatura/protocol/openid-connect/token`
  (`grant_type=client_credentials`, `client_id=siparis-sistemi`, realm dosyasındaki secret) → 200 (`1-canli-tarama.ps1` B,
  `b-canli-once.txt`).
- **Sonra:** aynı istek `localhost:8080`'e → 401 `unauthorized_client` (B2, `c-canli-sonra.txt`); `.env`'deki secret'la token
  alınıyor (`2-log-arama.ps1`, `b-log-arama.txt`).

### Y4 — Test kullanıcılarının şifreleri repoda: operatör yetkisi alınabiliyor (Yüksek, düzeltildi)

- **Ne:** `izleyici/izleyici123`, `operator/operator123`, `rolsuz/rolsuz123` realm dosyasıyla her kurulumda açılıyordu; şifreler
  public repodaydı ve her kurulumda geçerliydi.
- **Nerede:** `keycloak/fatura-realm.json` (`users`); ayrıca `InvoiceService.Api.http` ve test script'leri.
- **Nasıl istismar edilir:** Keycloak'a ulaşabilen biri operasyon ekranının giriş sayfasından `operator/operator123` ile girer.
- **Etki:** Operatör yetkisiyle yeniden gönderme, toplu yeniden gönderme, mutabakat başlatma; izleyiciyle bütün faturalar okunur.
- **Önem gerekçesi:** Şifreler herkesin bildiği bilgi, ama alınan şey bir bileşenin tamamı değil, Fatura Servisi'nin bir rolü:
  operatör faturalara müdahale eder, kullanıcı, rol ya da ayar değiştiremez. Tanımda "yetkiler ve faturaların durumu
  değiştirilebilir" Yüksek'tir.
- **Öneri:** Şifreler realm dosyasında olmasın, içe aktarılırken ortamdan verilsin (Y3 ile aynı yol).
- **Düzeltme:** Realm dosyasında `${TEST_IZLEYICI_PASSWORD}`, `${TEST_OPERATOR_PASSWORD}`, `${TEST_ROLSUZ_PASSWORD}`; compose
  `.env`'deki değerleri Keycloak'a veriyor, testlerin Keycloak'ı kendi test değerlerini veriyor; script'ler şifreleri `.env`'den
  okuyor, `.http` dosyasında değer yok (`.env`'den elle kopyalanır).
- **Önce:** istek `POST http://localhost:8080/realms/fatura/protocol/openid-connect/token` (`grant_type=password`,
  `client_id=fatura-test`, realm dosyasındaki şifreler) → üç kullanıcının token'ı alındı; operator `fatura-operatoru`, izleyici
  `fatura-izleyici` rolüyle (`manual-tests/gun17/1-hazir.ps1`, `manual-tests/output/gun17/gun17-1-hazir.txt`).
- **Sonra:** aynı istek eski şifrelerle → üçünde 400 `invalid_grant` (`1-canli-tarama.ps1` B2, `c-canli-sonra.txt`); `.env`'deki
  şifrelerle token alınıyor (`2-log-arama.ps1`, `b-log-arama.txt`).

### Y5 — ERP Simülatörü'nün API'si kimlik doğrulaması istemiyor (Kritik, önce Yüksek; kısmen: ağ erişimi kapatıldı)

- **Ne:** Fatura oluşturma, listeleme ve sorgulama token istemiyor; Swagger her ortamda açık. Fatura Servisi de ERP'ye hiçbir
  kimlik bilgisi göndermiyor.
- **Nerede:** `erp-simulator/src/ErpSimulator.Api/Invoices/InvoiceEndpoints.cs`, `Program.cs`;
  `invoice-service/src/InvoiceService.Infrastructure/Erp/ErpClient.cs`.
- **Nasıl istismar edilir:**
  - `GET /api/v1/invoices?from=…&to=…` ile bütün faturaların müşteri kodu, tutarı ve ERP referansı okunur.
  - Sıradaki fatura numarası (sıralı) için `POST` ile kayıt açılır; servisin ikinci denemesi bu kaydı benimser (O6).
  - Aynı numaraya ikinci bir kayıt açılırsa mutabakat o faturaya ERP kararını artık uygulamaz, yalnız raporlar
    (`ReconciliationPlanner.cs`, `records.Count == 1`).
  - Saniyede 20'lik ortak kota doldurulup servisin gönderimleri 429 aldırılır; her yazılan kayıt her mutabakatta "Serviste Yok"
    bulgusu olarak tekrar yazılır.
- **Etki:** Fatura verisi okunur; faturanın durumu ve hangi ERP kaydına bağlı olduğu dışarıdan değiştirilir; mutabakat belirli
  bir faturayı düzeltemez hale gelir.
- **Düzeltme:** Simülatöre ağdan erişim kapatıldı; port yalnız `127.0.0.1`'e açık (Y1). Açığın kendisi, API'nin kimlik
  doğrulaması istememesi, duruyor (Kalan).
- **Önce:** istek `GET http://<yerel ağ adresi>:5080/api/v1/invoices?from=…&to=…`, token'sız → 200 (`1-canli-tarama.ps1` C,
  `b-canli-once.txt`).
- **Sonra:** aynı istek → bağlantı kurulamıyor (C, `c-canli-sonra.txt`).
- **Kalan:** Uygulama katmanında kimlik doğrulaması hâlâ yok. Bu bilgisayardan ya da compose ağındaki bir container'dan
  simülatöre ulaşan biri yukarıdakilerin hepsini yapabilir.
- **Öneri:** Simülatör kimlik doğrulaması istesin (ör. `.env`'den gelen bir API anahtarı) ve Fatura Servisi bunu göndersin.
  Simülatör gerçek ERP'nin yerini tutuyor; gerçek ERP'ye geçildiğinde de Fatura Servisi'nin kimlik bilgisi göndermesi ve ERP
  cevabına içerik karşılaştırmadan güvenmemesi (O6) gerekir.

### O1 — Kaba kuvvet koruması ve şifre politikası yok; `admin-cli` şifreyle token veriyor (Orta; kaba kuvvet ve şifre politikası düzeltildi)

- **Ne:** Realm'de `bruteForceProtected: false`, `passwordPolicy` boş. `fatura` realm'inin `admin-cli` client'ı public ve
  şifreyle token veriyor (`directAccessGrantsEnabled`).
- **Nerede:** `keycloak/fatura-realm.json` (realm ayarları), Keycloak varsayılanları.
- **Nasıl istismar edilir:** Bir hesabın şifresi sınırsız sayıda denenir; `admin-cli` ile giriş sayfasına uğramadan denenebilir
  (bu token'ın audience'ı olmadığı için API kabul etmez, ama doğru şifre öğrenilir).
- **Etki:** Zayıf şifreli bir hesabın ele geçmesi kolaylaşır.
- **Öneri:** `bruteForceProtected` ve bir şifre politikası açılsın; `fatura` realm'inde `admin-cli`'nin şifreyle token vermesi kapatılsın.
- **Düzeltme:** Realm dosyasında `bruteForceProtected: true`, `failureFactor: 5`, `waitIncrementSeconds: 60`,
  `maxFailureWaitSeconds: 900`, `permanentLockout: false`: art arda 5 yanlış şifreden sonra kullanıcı 60 sn kilitlenir, tekrar
  ederse süre 15 dk'ya kadar uzar; kalıcı kilit yok (saldırgan gerçek kullanıcıyı bilerek kilitleyemesin).
  `passwordPolicy: "length(12) and notUsername and notEmail"`. Politika test kullanıcılarının içe aktarılan şifrelerine de
  uygulanıyor: `.env`'deki bir test şifresi uymuyorsa Keycloak açılmıyor (4 karakterlik şifreyle açılış içe aktarması
  `invalidPasswordMinLengthMessage` ile durdu, `c-sifre-politikasi-ice-aktarma.txt`).
- **Önce:** istek: geçici kullanıcıyla `fatura-test` client'ından 5 yanlış şifre, ardından doğru şifre → 200;
  yönetim API'sinde `attack-detection` `disabled=false`, `numFailures=0`; yönetim API'siyle şifreyi `kisa1` yapma → 204
  (`manual-tests/gun21/1-once-sonra.ps1` O1, `b-once.txt`).
- **Sonra:** aynı istekler → doğru şifre 400 `invalid_grant`; `disabled=true`, `numFailures=5`; 65 sn sonra doğru şifre 200;
  `kisa1` → 400 `Invalid password: minimum length 12.` (`c-sonra.txt`). Test:
  `RealmSecurityTests.After_five_wrong_passwords_in_a_row_the_right_password_is_refused_and_the_user_is_locked` (realm'in bir
  kopyasında; `bruteForceProtected` geri alınınca kırılıyor, `c-mutasyon-realm.txt`).
- **Kalan (öneri):** `fatura` realm'inde `admin-cli` hâlâ şifreyle token veriyor.

### O2 — Grafana yönetici hesabı imajın varsayılanı (Kritik, önce Orta; düzeltildi)

- **Ne:** Grafana'nın yönetici şifresi değiştirilmemiş (`admin/admin`); anonim kullanıcı panoyu görüyor.
- **Nerede:** `docker-compose.yml` (`grafana`; `GF_SECURITY_ADMIN_PASSWORD` yok).
- **Nasıl istismar edilir:** Grafana'ya ulaşabilen biri (düzeltmeden önce aynı ağdaki herkes) `admin/admin` ile girer, adresi
  compose ağındaki bir servis olan bir veri kaynağı ekler ve Grafana'nın veri kaynağı proxy'si üzerinden o servise istek attırır.
- **Etki:** Panolar ve veri kaynakları değiştirilir; Grafana'nın ulaştığı servislere onun adına istek gönderilir. Denemede
  ERP Simülatörü'nü gösteren bir veri kaynağı eklendi ve onun üzerinden fatura listesi (müşteri kodu, tutar, ERP referansı)
  okundu: HTTP 200, `totalCount` 6.021 (`a0-grafana-yonetici-ssrf.txt`, düzeltmeden önceki ayarlarla geçici container).
- **Öneri:** `GF_SECURITY_ADMIN_PASSWORD` ortamdan verilsin.
- **Düzeltme:** Şifre `.env`'deki `GRAFANA_ADMIN_PASSWORD`'den; değer yoksa compose açılmıyor. Anonim izleyici kapatıldı:
  anonim izleyici Grafana'nın veri kaynağı üzerinden Prometheus'a istediği sorguyu gönderebiliyordu, bu da O3'te Prometheus'un
  önüne konan girişi atlatırdı. Pano için artık giriş gerekiyor.
- **Önce:** istek `POST http://localhost:3000/login` (`admin/admin`) → 200 (`1-once-sonra.ps1` O2, `b-once.txt`); girişsiz
  `GET /api/datasources/proxy/uid/prometheus/api/v1/query?query=up` → 200, Prometheus'un cevabı (`b-grafana-anonim-once.txt`).
- **Sonra:** `admin/admin` → 401; `.env`'deki şifreyle → 200; girişsiz veri kaynağı sorgusu → 401 (`c-sonra.txt`). Tarayıcıda:
  girişsiz açılış giriş sayfasına gidiyor, sayfanın `/api/search` isteği 401; giriş formunda `admin/admin` → "Invalid username
  or password"; `.env`'deki şifreyle giriş Fatura Servisi panosunu verisiyle açıyor (`c-tarayici-grafana.txt`).
- **Kalan:** Grafana'da tek hesap `admin`; panoya bakan herkes bu şifreyle giriyor (kişiye bağlı giriş yok).

### O3 — Alertmanager, Prometheus ve Jaeger kimlik doğrulaması istemiyor (Kritik, önce Orta; düzeltildi)

- **Ne:** Üçünün de arayüzü ve API'si kimliksiz.
- **Nerede:** `docker-compose.yml`, `monitoring/`.
- **Nasıl istismar edilir:** Alertmanager'a `POST /api/v2/silences` ile alarmları susturan bir kayıt yazılır; Prometheus'tan
  ayarlar ve metrikler, Jaeger'dan fatura numaralı izler okunur.
- **Etki:** Bir saldırı sırasında alarmlar sessizce kapatılabilir; iç yapı, fatura numaraları ve ERP referansları okunur
  (ERP referansı Y2'deki sahte haberin ön koşulu; `a0-jaeger-fatura-verisi.txt`).
- **Öneri:** Dışarıya açılacaksa önlerine kimlik doğrulayan bir reverse proxy konsun.
- **Düzeltme (O10 ile birlikte):** Üç aracın portları artık yayımlanmıyor; önlerinde `izleme-girisi` (nginx) aynı adresleri
  (9090, 9093, 16686) dinliyor ve her isteği `oauth2-proxy`'ye soruyor (`auth_request`). Giriş Keycloak'ın `izleme-girisi`
  client'ıyla (Authorization Code + PKCE, confidential); yalnız `fatura-operatoru` rolü geçiyor. Script'ler bu client'tan
  alınmış token'ı `Bearer` ile gönderebiliyor (audience `izleme-girisi`; Fatura Servisi'nin token'ı geçmiyor). Oturum
  şifreli bir çerezde tutuluyor. Ayar `monitoring/izleme-girisi/`, `docker-compose.yml`.
  - **Neden bu yol:** Kimlik doğrulaması zaten Keycloak'ta; kişiye bağlı giriş, rol kontrolü ve O1'deki kilit buraya da
    uygulanıyor, yeni bir ortak şifre yok. Ortak şifreli basic auth seçilmedi: herkes aynı şifreyi kullanır, şifre her istekte
    HTTP üzerinden gider (O5) ve kilit koruması yoktur. Araçların kendi basic auth'u (Prometheus, Alertmanager `web.config`)
    Jaeger'ı kapsamıyor ve Alertmanager'ın CORS başlığını kaldırmıyor.
- **Önce:** istekler token'sız: `GET :9090/api/v1/query?query=up`, `GET :9093/api/v2/alerts`, `GET :16686/api/services` → 200;
  `POST :9093/api/v2/silences` → 200, susturma kaydı yazıldı (hemen silindi) (`1-once-sonra.ps1` O3, `b-once.txt`).
- **Sonra:** aynı istekler token'sız → 302 (Keycloak girişine); operator'ün `izleme-girisi` token'ıyla → 200; izleyicinin
  token'ıyla (rol yok) ve operator'ün Fatura Servisi token'ıyla (audience farklı) → 302 (`c-sonra.txt`). Tarayıcıda:
  `localhost:9090` Keycloak'ın giriş sayfasına gidiyor; izleyici girişten sonra 403; operator girişten sonra Prometheus, aynı
  oturumla Alertmanager ve Jaeger giriş sorulmadan açılıyor (`c-tarayici-izleme-girisi.txt`).
- **Kalan:** compose ağının içinden araçlara doğrudan ulaşılıyor (Grafana → Prometheus, Prometheus → Alertmanager); bu,
  compose ağındaki bir container'a erişim gerektiriyor (D11 ile aynı sınır). Girişten sonraki oturum oauth2-proxy'nin
  varsayılanıyla 7 gün geçerli ve Keycloak'a yeniden sorulmuyor: Keycloak'ta oturum kapatıldıktan sonra da aynı çerezle erişim
  sürüyor (`c-tarayici-izleme-girisi.txt`).

### O4 — Operasyon ekranında HTTP güvenlik başlıkları yok (Orta; ekran düzeltildi)

- **Ne:** `Content-Security-Policy`, `X-Frame-Options` (ya da `frame-ancestors`), `X-Content-Type-Options`, `Referrer-Policy`,
  `Permissions-Policy` yok; `Server: nginx/1.31.8` sürüm bilgisi veriyor; API'nin cevabında da `Server` başlığı var (Kestrel varsayılanı).
- **Nerede:** `operations-ui/nginx.conf`, Kestrel varsayılanı.
- **Nasıl istismar edilir:** Ekran başka bir sitenin içine iframe ile gömülüp operatöre "Yeniden gönder"e tıklatılır
  (clickjacking); bir XSS olursa CSP onu sınırlamaz.
- **Etki:** Operatörün haberi olmadan müdahale; XSS durumunda bellekteki token'ın okunması.
- **Öneri:** nginx'e `Content-Security-Policy` (`default-src 'self'`, `connect-src` API ve Keycloak, `frame-ancestors 'none'`),
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`; `server_tokens off`; Kestrel'de `AddServerHeader = false`.
- **Düzeltme:** `operations-ui/security-headers.inc.template`: `Content-Security-Policy: default-src 'self'; script-src 'self';
  style-src 'self'; img-src 'self' data:; connect-src 'self' <API> <Keycloak>; object-src 'none'; base-uri 'self';
  form-action 'self'; frame-ancestors 'none'`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`,
  `Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=()` (ekran bunları kullanmıyor); her
  location'a ve hata cevaplarına (`always`) ekleniyor. `connect-src`'deki adresler ekranın derlendiği `VITE_API_URL` ve
  `VITE_KEYCLOAK_URL`'den geliyor (nginx imajının template özelliği). `server_tokens off`. Derlenen sayfada satır içi script ya
  da stil yok; CSP `'unsafe-inline'` gerektirmiyor.
- **Önce:** istek `GET http://localhost:5100/`, bir asset ve olmayan bir asset (404) → üçünde de `Content-Security-Policy`,
  `X-Content-Type-Options`, `Referrer-Policy` yok, `Server: nginx/1.31.8` (`1-once-sonra.ps1` O4, `b-once.txt`).
- **Sonra:** üçünde de başlıklar var, `Server: nginx` (`c-sonra.txt`). Ekran uygulama içi tarayıcıda: giriş, Özet, Fatura
  Listesi, Fatura Detayı, Mutabakat (mutabakat başlatma POST'u dahil) çalıştı; sayfa içinden dinlenen
  `securitypolicyviolation` olayı yok, konsolda hata yok; iki sekme aynı anda açıkken ikisinde de token yenilendi
  (`c-tarayici-ekran.txt`).
- **Kalan (öneri):** API'nin cevabındaki `Server: Kestrel` başlığı.

### O5 — Bütün trafik HTTP üzerinden (Orta)

- **Ne:** Keycloak `start-dev` ile HTTP'de, servis `RequireHttpsMetadata = false`, compose'da TLS yok.
- **Nerede:** `docker-compose.yml`, `AuthExtensions.cs`.
- **Nasıl istismar edilir:** Ağı dinleyebilen biri token'ları ve Keycloak'a girilen şifreleri okur.
- **Etki:** Token ve şifre çalınması.
- **Öneri:** Yerel geliştirme dışındaki her kurulumda TLS; Keycloak `start`, `RequireHttpsMetadata = true`.

### O6 — ERP'deki kayıt içeriği karşılaştırılmadan faturaya bağlanıyor (Orta)

- **Ne:** İkinci denemeden itibaren servis önce ERP'ye "bu numara sende var mı?" diye soruyor; cevap evetse kaydın referansını
  alıp faturayı Gönderildi yapıyor, tutar/müşteri karşılaştırmıyor. Son denemeden sonraki soru da aynı. Mutabakat ise
  karşılaştırıyor; aynı karar iki yerde farklı uygulanıyor.
- **Nerede:** `invoice-service/src/InvoiceService.Application/Outbox/ErpSendStrategy.cs` (`SendOnceAsync`, `ConfirmAsync`).
- **Nasıl istismar edilir:** ERP'ye yazabilen biri (Y5) servisin ilk denemesi başarısız olan bir fatura için aynı numarayla
  kendi kaydını açar; servis bu kaydı benimser, simülatör ona imzalı haber üretir.
- **Etki:** Faturanın ERP'deki karşılığı başka içerikli bir kayıt olur; durum o kayda göre değişir.
- **Öneri:** Benimsemeden önce tutar, para birimi, müşteri ve tarih karşılaştırılsın; uyuşmazsa bulgu olsun.

### O7 — Tarayıcı client'ı offline token alabiliyor; refresh token tekrar kullanılabiliyor (Orta; ekranın client'ı ve refresh token düzeltildi)

- **Ne:** `offline_access` varsayılan rollerde ve `operasyon-ekrani`'nın isteğe bağlı scope'larında; offline oturum 30 gün boşta
  kalabiliyor, en uzun süre sınırı kapalı; `revokeRefreshToken: false`.
- **Nerede:** Keycloak realm varsayılanları (`keycloak/fatura-realm.json`'da ayarlanmamış).
- **Nasıl istismar edilir:** Kullanıcı (ya da tarayıcısında kod çalıştıran biri) `scope=openid offline_access` ile offline
  refresh token alır.
- **Etki:** Bu token SSO süreleri, ekranın 15 dk işlemsizlik kapanması ve çıkıştan bağımsız; çalınırsa uzun ömürlü kimlik bilgisi olur.
- **Öneri:** `offline_access` varsayılan rollerden ve ekranın scope'larından çıkarılsın; offline oturuma en uzun süre ve
  `revokeRefreshToken` açılsın.
- **Düzeltme:** `operasyon-ekrani`'nın isteğe bağlı scope'larından `offline_access` çıkarıldı (varsayılan scope'lar da açıkça
  yazıldı: yalnız isteğe bağlılar yazılınca Keycloak varsayılanları boş bırakıyor). Realm'de `revokeRefreshToken: true`,
  `refreshTokenMaxReuse: 0` (refresh token rotation): her yenilemede yeni refresh token veriliyor, kullanılmış olan ikinci kez
  reddediliyor ve Keycloak oturumun bu client'taki kaydını kapatıyor; çalınmış bir token kullanılırsa meşru sahibinin token'ı
  da geçersiz kalır.
- **Önce:** istek: yönetim API'siyle açılan bir kullanıcıyla (varsayılan rollerden `offline_access`'i var) ekranın giriş akışı,
  `scope=openid offline_access` → refresh token türü `Offline`; `scope=openid` ile alınan refresh token iki kez kullanıldı →
  ikisi de 200 (`1-once-sonra.ps1` O7, `b-once.txt`). Realm dosyasıyla içe aktarılan test kullanıcılarında `offline_access`
  rolü yok; onlara offline token zaten verilmiyordu.
- **Sonra:** `offline_access` isteği → `invalid_scope`; aynı refresh token 1. kullanım 200, 2. kullanım 400 `invalid_grant`
  (`Maximum allowed refresh token reuse exceeded`); 1. kullanımda verilen yeni token da ardından 400 (`c-sonra.txt`). Testler:
  `RealmSecurityTests.The_operations_screen_asking_for_an_offline_token_is_refused`,
  `RealmSecurityTests.A_refresh_token_used_once_is_refused_the_second_time` (ayar geri alınınca kırılıyor, `c-mutasyon-realm.txt`).
- **Kalan (öneri):** `offline_access` realm'in varsayılan rollerinde duruyor (dosyadan çıkarıldığında Keycloak içe aktarırken
  geri ekledi); ekranın client'ı onu isteyemiyor, diğer client'ların scope listeleri değiştirilmedi. Offline oturumun en uzun süresi.

### O8 — Güvenlik olayları saklanmıyor ve izlenmiyor (Orta)

- **Ne:** Keycloak'ta `eventsEnabled` ve `adminEventsEnabled` kapalı: başarısız girişler yalnız container loguna yazılıyor
  (`jboss-logging`, `LOGIN_ERROR`), olaylar saklanmıyor, yönetici değişiklikleri kaydedilmiyor. Fatura Servisi'nin 401/403
  cevapları gönderilen log seviyesinde yazılmıyor, metrik ve alarm yok (alarm yalnız webhook 401'i için).
- **Nerede:** realm, `invoice-service/.../appsettings.json` (`Microsoft.AspNetCore: Warning`), `monitoring/prometheus/alert-rules.yml`.
- **Nasıl istismar edilir:** Çalıntı ya da bozuk token'la ve yetkisiz müdahale denemeleri API'de iz bırakmaz; şifre denemeleri
  yalnız Keycloak'ın container logunda kalır, olay olarak sorgulanamaz; yönetici değişiklikleri kaydedilmez.
- **Etki:** Saldırı fark edilmez, sonradan incelenemez.
- **Öneri:** Keycloak olay kaydı açılsın; serviste 401/403 için bir log satırı ve metrik, yoğunlaşınca alarm.

### O9 — Uygulamaların veritabanı kullanıcıları süper kullanıcı (Orta, düzeltildi)

- **Ne:** `invoice` ve `erp` kullanıcıları `rolsuper=t` (resmi PostgreSQL imajında `POSTGRES_USER` süper kullanıcı olur).
- **Nerede:** `docker-compose.yml`, bağlantı dizeleri.
- **Nasıl istismar edilir:** Bir SQL enjeksiyonu (bulunmadı) ya da sızan bağlantı bilgisiyle bütün veritabanı ve
  `COPY … TO PROGRAM` ile veritabanı container'ında komut çalıştırma.
- **Etki:** Başka bir açığın etkisini en üst düzeye çıkarır.
- **Öneri:** Migration için yönetici kullanıcı, uygulama için yalnız gereken tablolarda yetkisi olan ayrı bir kullanıcı.
- **Düzeltme:** Migration'ları artık uygulamalar açılışta değil, ayrı ve bir kez çalışıp kapanan `invoice-migrate` ve
  `erp-migrate` container'ları çalıştırıyor (aynı imaj, `--migrate-only`), veritabanının sahibiyle (`invoice`, `erp`). Bu adım
  migration'lardan sonra uygulama kullanıcısını (`invoice_app`, `erp_app`; şifreler `.env`'de) oluşturuyor ya da şifresini
  güncelliyor ve yetkilerini veriyor: bütün tablolarda `SELECT`, `INSERT`; `UPDATE` yalnız uygulamanın satırını değiştirdiği
  tablolarda (Fatura Servisi: `invoices`, `erp_outbox`, `erp_webhook_events`, `invoice_follow_ups`, `reconciliation_runs`,
  `erp_send_pace`; simülatör: `webhook_deliveries`). Yalnız eklenen tablolarda (`operator_actions`, `reconciliation_findings`,
  simülatörün `invoices`'ı) `UPDATE` yok: yazılmış bir müdahale kaydı sonradan değiştirilemez. `DELETE` hiçbir tabloda yok
  (uygulamalar satır silmiyor). Sequence'larda `USAGE`, `SELECT`, yalnız kendi veritabanına `CONNECT`; migration geçmişi
  tablosuna yetki yok, hiçbir tablonun sahibi değil.
  `postgres` ve `template1`'in herkese açık `CONNECT` izni kaldırıldı. Uygulamalar migrate adımı başarıyla bitmeden açılmıyor.
  - **Neden bu yol:** Uygulama açılışta kendisi migrate etseydi sahibin şifresini de taşımak zorunda kalırdı; o zaman
    uygulamayı ele geçiren tablo silebilirdi. Adım her açılışta tekrar çalıştığı için yeni bir migration'ın tabloları da
    yetkiye girer ve eski volume'larda elle bir şey yapmak gerekmez.
- **Önce:** istek: uygulamanın kendi bağlantı dizesindeki kullanıcıyla (`invoice`, `erp`) `rolsuper` → `t`;
  `BEGIN; DROP TABLE invoices CASCADE; ROLLBACK;` → silindi (geri alındı); aynı sunucudaki `postgres` veritabanına bağlantı →
  bağlandı (`1-once-sonra.ps1` O9, `b-once.txt`).
- **Sonra:** `invoice_app` ve `erp_app` ile → `rolsuper` `f`; `DROP TABLE` → `must be owner of table invoices`; `postgres` →
  `User does not have CONNECT privilege`; diğer uygulamanın veritabanı sunucusu → `password authentication failed` (kullanıcı
  orada yok) (`c-sonra.txt`). İkinci servis kopyası (`invoice-service-2`, `iki-kopya` profili) de `invoice_app` ile bağlanıyor,
  ona gönderilen fatura ERP'ye ulaştı, logunda yetki hatası yok; compose dışında `dotnet run -- --migrate-only` boş bir deneme
  veritabanında migration'ları uyguladı ve kullanıcıyı oluşturdu, o kullanıcıyla `DROP TABLE` → `must be owner`
  (`3-ikinci-kopya-ve-migrate.ps1`, `c-ikinci-kopya-ve-migrate.txt`).

### O10 — Alertmanager ve Prometheus her web sitesine CORS izni veriyor (Orta, düzeltildi)

- **Ne:** Alertmanager `Access-Control-Allow-Origin: *` ve preflight'ta `POST` + `content-type` izni; Prometheus
  `--web.cors.origin=.*` (varsayılan) ile her origin'i yansıtıyor.
- **Nerede:** `docker-compose.yml` (iki servisin CORS ayarı yok).
- **Nasıl istismar edilir:** Yığın çalışırken geliştiricinin ya da operatörün tarayıcısında açılan herhangi bir sayfa
  `localhost:9093`'e alarm susturma yazar, `localhost:9090`'dan metrik ve ayar okur. Port daraltması (Y1) bunu engellemez:
  isteği kurbanın tarayıcısı atar.
- **Etki:** Alarmların uzaktan susturulması; metriklerin okunması.
- **Öneri:** Prometheus'a `--web.cors.origin` ile yalnız Grafana; Alertmanager'ın önüne kimlik doğrulayan bir proxy (O3).
- **Düzeltme:** O3'teki giriş kapısı: oturumu ya da token'ı olmayan istek araca ulaşmıyor; geçen isteklerin cevabından
  `Access-Control-*` başlıkları siliniyor. Oturum çerezi `SameSite=Lax`. Grafana Prometheus'a
  sunucu tarafından bağlandığı için (`access: proxy`) CORS'a ihtiyacı yok.
- **Önce:** istek `GET :9090/api/v1/query?query=up`, `Origin: http://kotu-site.example` → 200,
  `Access-Control-Allow-Origin: http://kotu-site.example`; Alertmanager'a `POST /api/v2/silences` preflight'ı → 204,
  `Access-Control-Allow-Origin: *` (`1-once-sonra.ps1` O10, `b-once.txt`).
- **Sonra:** token'sız → 302, başlık yok; operator token'ıyla → 200, başlık yok (iki araçta da) (`c-sonra.txt`). Tarayıcıda,
  başka bir sitenin sayfasından (`localhost:18080`) çerezsiz ve çerezli `fetch`: eski ayarlı Alertmanager ve Prometheus'un
  cevabı çerezsiz istekte okundu (HTTP 200), giriş kapısının arkasındakilerin dört isteğinin hiçbiri okunamadı
  (`c-tarayici-cors.txt`, `c-tarayici-cors.jpg`).

### D1 — Geliştirme bağımlılığında bilinen açıklar (Düşük)

- **Ne:** `npm audit`: `vitest`/`@vitest/mocker`'da 2 moderate: GHSA-qxg6-89mg-rqv8 (kimliksiz manual mock kaydıyla kod
  enjeksiyonu) ve GHSA-xp26-3454-mjgp (Windows'ta yol kontrolünün aşılması).
- **Nerede:** `operations-ui/package.json` (devDependencies).
- **Nasıl istismar edilir:** Yalnız geliştirici testleri çalıştırırken; vitest'in kendi sunucusuna erişim gerektirir.
- **Etki:** Geliştiricinin bilgisayarıyla sınırlı; ekranın imajına girmiyor (`npm audit --omit=dev`: 0).
- **Öneri:** vitest düzeltilmiş sürüme yükseltilsin.

### D2 — ERP Simülatörü'nün 409 cevabı mevcut ERP referansını söylüyor (Düşük)

- **Ne:** Aynı numarayla farklı içerikli fatura gönderilince cevap var olan kaydın referansını yazıyor.
- **Nerede:** `erp-simulator/src/ErpSimulator.Api/Invoices/InvoiceEndpoints.cs` (`SubmitOutcome.Conflict`).
- **Nasıl istismar edilir:** `IdempotentInvoices` açıkken bir numaraya farklı içerikle POST atılır, cevaptan referans okunur.
- **Etki:** Referans başka yoldan da okunabildiği (Y5) için ek etkisi küçük.
- **Öneri:** Cevapta referans yazılmasın.

### D3 — Uygulama container'ları root olarak çalışıyor (Düşük)

- **Ne:** `invoice-service`, `erp-simulator`, `alert-receiver` ve `operations-ui` container'ları `uid=0`.
- **Nerede:** Dockerfile'lar (son aşamada `USER` yok).
- **Nasıl istismar edilir:** Önce uygulamada kod çalıştırma açığı gerekir; o zaman container içinde root olunur.
- **Etki:** Container'dan kaçışın etkisi büyür.
- **Öneri:** .NET imajlarında `USER $APP_UID`; nginx için yetkisiz kullanıcıyla çalışan imaj.

### D4 — Keycloak yönetim konsolu kullanıcı giriş adresiyle aynı yerde (Düşük)

- **Ne:** `/admin/master/console/` kullanıcıların giriş yaptığı adres ve porttan açılıyor.
- **Nerede:** `docker-compose.yml` (keycloak).
- **Nasıl istismar edilir:** Giriş sayfasına ulaşabilen herkes yönetim konsoluna da ulaşır; K1 gibi bir zayıflığın yüzeyini büyütür.
- **Etki:** Saldırı yüzeyi.
- **Öneri:** Yönetim için ayrı hostname/port (`KC_HOSTNAME_ADMIN`) ve yalnız iç ağdan erişim.

### D5 — İmaj ve GitHub Actions sürümleri sabit değil; workflow yetkisi sınırsız (Düşük)

- **Ne:** `sdk:10.0`, `aspnet:10.0`, `nginx:alpine`, `node:22-alpine` kayan etiketler; Actions `@v4` (commit SHA değil);
  workflow'da `permissions:` yok.
- **Nerede:** Dockerfile'lar, `.github/workflows/invoice-service-tests.yml`.
- **Nasıl istismar edilir:** Taşınan bir etiket derlemeye haberimiz olmadan farklı içerik sokar (tedarik zinciri).
- **Etki:** Derlenen imajın ne içerdiği derlemeden derlemeye değişir; `GITHUB_TOKEN` gereğinden geniş olabilir.
- **Öneri:** Sürüm ve tercihen digest; Actions'ta commit SHA; `permissions: contents: read`.

### D6 — Fatura Servisi'nde hız sınırı yok (Düşük)

- **Ne:** Rate limiter yok; JSON gövdeli endpoint'lerde gövde sınırı Kestrel varsayılanı (30 MB), webhook 64 KB.
- **Nerede:** `invoice-service/src/InvoiceService.Api/Program.cs`.
- **Nasıl istismar edilir:** Geçerli bir token'la okuma uçları sınırsız çağrılır.
- **Etki:** Veritabanı ve worker'lar yavaşlar, veri değişmez.
- **Önem gerekçesi:** Tanımda kullanılabilirlik için ayrı bir ölçüt yok; yavaşlatma geçerli bir token gerektirdiği ve veri
  değişmediği için "istismarı zor, etkisi sınırlı" sayıldı.
- **Öneri:** `AddRateLimiter` ile kullanıcı ve IP başına sınır; JSON uçlarında küçük `MaxRequestBodySize`.

### D7 — Çalışan Keycloak'ta şifreyle token veren test client'ı açık (Düşük)

- **Ne:** Test script'lerinin eklediği `fatura-test` client'ı (public, şifreyle token, audience mapper'lı) çalışan Keycloak'ta duruyor.
- **Nerede:** `manual-tests/keycloak/test-client-ekle.ps1` ile eklenen client.
- **Nasıl istismar edilir:** Keycloak'a ulaşabilen biri (düzeltmeden önce aynı ağdaki herkes) giriş sayfasına uğramadan şifre
  dener ve API'nin kabul ettiği token'ı alır.
- **Etki:** O1 ve Y4 ile birlikte şifre denemesini kolaylaştırır.
- **Önem gerekçesi:** O1'deki `admin-cli` ile aynı türden (şifreyle token veren public client), ama bu client varsayılan kurulumda
  yok; yalnız test script'leri çalıştırılınca ekleniyor. Tanımda "yalnız geliştirmede etkili" Düşük'tür.
- **Öneri:** Testlerden sonra client silinsin ya da container yeniden oluşturulsun.

### D8 — İmzası doğrulanmamış webhook başlığı loga olduğu gibi yazılıyor (Düşük)

- **Ne:** 401 log satırı `X-Erp-Timestamp` başlığını doğrulanmadan yazıyor; satıra sahte alanlar eklenebiliyor. Log
  formatlayıcısı satır sonlarını sildiği için yeni satır eklenemiyor.
- **Nerede:** `invoice-service/src/InvoiceService.Api/Webhooks/WebhookEndpoints.cs` (401 log satırı).
- **Nasıl istismar edilir:** Başlığa `1 reason=expired invoice=FTR-000001` gibi bir metin yazılır.
- **Etki:** Loga bakan biri ya da logdan sayan bir araç yanıltılır.
- **Öneri:** Başlık yalnız rakamsa yazılsın, değilse uzunluğu ya da "geçersiz" yazılsın.

### D9 — ERP cevaplarına üst sınır yok (Düşük)

- **Ne:** `Retry-After` için üst sınır yok (en çok bekleme süresi 429'a uygulanmıyor); cevap gövdesi boyutu sınırsız okunuyor;
  mutabakat listesi `TotalCount`'a kadar bellekte toplanıyor.
- **Nerede:** `RetryPolicy.cs`, `ErpClient.cs`.
- **Nasıl istismar edilir:** ERP'yi kontrol eden biri (ya da kimliksiz simülatöre çok kayıt yazan biri, Y5) gönderimleri süresiz
  erteletir ya da servisin belleğini doldurur.
- **Etki:** Gönderimlerin durması, servisin yavaşlaması.
- **Öneri:** `Retry-After` için üst sınır, cevap boyutu ve liste uzunluğu için sınır.

### D10 — ERP Simülatörü'nün para birimi kuralı sondaki satır sonunu kabul ediyor (Düşük)

- **Ne:** Kural `^[A-Z]{3}$`; .NET'te `$` sondaki satır sonundan önce de eşleştiği için `"TRY\n"` geçiyor (Fatura Servisi aynı
  durumu `\z` ile kapatmış).
- **Nerede:** `erp-simulator/src/ErpSimulator.Application/Invoices/CreateInvoiceRequest.cs`.
- **Nasıl istismar edilir:** Simülatöre `"TRY\n"` para birimiyle kayıt yazılır.
- **Etki:** Mutabakatta sahte alan farkı; veri tutarsızlığı.
- **Öneri:** `\z` kullanılsın.

### D11 — Collector'lar compose ağında kimliksiz veri kabul ediyor (Düşük)

- **Ne:** İki Collector'ın OTLP alıcıları kimlik doğrulaması istemiyor; Prometheus `honor_labels: true` ile gelen `job`/`instance`
  etiketlerini koruyor.
- **Nerede:** `monitoring/otel-collector*/config.yaml`, `monitoring/prometheus/prometheus.yml`.
- **Nasıl istismar edilir:** compose ağındaki herhangi bir container sahte metrik ya da iz gönderir.
- **Etki:** Pano ve alarmlar yanıltılır.
- **Öneri:** OTLP alıcılarına kimlik doğrulama (ör. bearer token extension) ya da ağ ayrımı.

## Bakılan konular

Görev mailinin saydığı konular, aynı sırayla.

### Kimlik doğrulama ve yetkilendirme

- **Nasıl bakıldı:** her endpoint'in yetki kuralı, `FallbackPolicy`, JwtBearer ayarları, operatör kimliğinin okunduğu yer, anahtar
  yenileme (kütüphanenin kaynağı ve test), realm dosyası ve çalışan realm'in ayarları (yönetim API'si); canlıda token'sız istekler.
- **Sonuç:** Token istemeyen yalnız `/health` (`{"status":"ok"}`) ve ERP webhook'u (HMAC'li); Swagger ve OpenAPI de token istiyor.
  Kural yazılmamış yeni bir endpoint de token ister. Operatör adı ve `sub` token'dan okunuyor. Rol ve audience kurallarının her
  biri entegrasyon testleriyle sınanıyor. Bulgular: K1, Y3, Y4, Y5, O1, O2, O7, D4, D7.
  Anahtar listesinin (JWKS) yenilenme sıklığı görevin "Önce bir düzeltme" bölümünde ayara bağlandı ve testle gösterildi;
  kaldırılan bir anahtarın en kötü durumdaki kabul süresi hesabıyla README'de (Kimlik doğrulama).

### Webhook imzası

- **Nasıl bakıldı:** `WebhookSignature.cs`, `WebhookEndpoints.cs`, `WebhookRequestReader.cs`; canlıda doğru, yanlış ve sahte imzalı istek.
- **Sonuç:** Doğrulamada bulgu yok: imza zaman damgasını kapsıyor, karşılaştırma sabit sürede (`FixedTimeEquals`), 300 sn'den eski
  ya da ileri zaman damgası 401, gövde imzadan önce 64 KB ile sınırlı, iki kez gönderilen başlık geçersiz, aynı `event_id` ikinci
  kez uygulanmıyor, gövde imza doğrulanmadan işlenmiyor, 401 cevabı nedeni söylemiyor. Bulgular: Y2 (anahtarın saklandığı yer), D8.

### CORS

- **Nasıl bakıldı:** `CorsExtensions.cs`, ayar; canlıda Fatura Servisi'ne üç preflight; izleme araçlarına ve simülatöre başka origin'den istek.
- **Sonuç:** Fatura Servisi'nde bulgu yok: tek origin `http://localhost:5100`; `*`, yol içeren ya da geçersiz origin servis açılırken
  reddediliyor; yalnız `GET`/`POST` ve `Content-Type`, `Authorization`; credentials kapalı; `http://kotu-site.example` ve `null`
  origin'e izin dönmüyor. Bulgu: O10 (Alertmanager, Prometheus; düzeltildi). Keycloak'ın discovery belgesinin CORS'u açık, ama belge herkese açık.

### Kodda ve ayar dosyalarında duran şifre ve secret'lar

- **Nasıl bakıldı:** ayar dosyaları, compose, realm dosyası, script'ler, `.http` dosyaları; git geçmişinde (`git log --all -p`) özel
  anahtar, GitHub/AWS token biçimleri, `secret`, `password`, `Password=` araması.
- **Sonuç:** Geçmişte yalnız "dev-only" değerler ve test şifreleri var, gerçek bir anahtar yok. K1, K2, Y2, Y3, Y4'in değerleri
  `.env`'e taşındı; eski değerler geçmişte duruyor, `1-canli-tarama.ps1` B2'de bu kurulumda geçersiz oldukları görüldü. Repoda
  kalan: O2 (Grafana imajının varsayılanı; düzeltildi, şifre `.env`'de); eski ve artık geçersiz değerler ERP Simülatörü'nün birim testlerinin sabitlerinde
  (`WebhookPlannerTests.cs:21`, `:132`, `WebhookSenderTests.cs:14`), `AdvisoryReconciliationLockTests.cs:8` (`Password=invoice`,
  testin kendi container'ı) ve eski değerlerin reddedildiğini sınayan `1-canli-tarama.ps1`'de (bilerek).

### Hata mesajlarında ve loglarda dışarı sızan bilgi

- **Nasıl bakıldı:** `UseExceptionHandler` + ProblemDetails, log satırları ve formatlayıcı; canlıda bozuk JSON, 5000 karakterlik
  fatura numarası, simülatöre bozuk JSON. `2-log-arama.ps1`: token'lı (sipariş sistemi ve üç kullanıcı), token'sız, imzası bozuk,
  Basic şifreli istekler, Keycloak'a yanlış şifreyle giriş, imzalı ve yanlış imzalı webhook; sonra bütün container'ların
  isteklerden sonraki loglarında ve şu anki container'ların açılışından bu yana bütün loglarında (realm içe aktarma, yönetici hesabının oluşturulması,
  servislerin ayar satırları dahil) 23 arama: o koşuda alınan token'lar ve imza kısımları, her JWT biçimi, `Bearer` + değer, `Authorization`, `.env`'deki sekiz
  değerin her biri kendi değeriyle (iki veritabanı şifresi, Keycloak yönetici şifresi, webhook ve client secret'ı, üç test
  kullanıcısının şifresi), yanlış girilen şifre, Basic kimlik bilgisi, `Password=`, `client_secret=`. Jaeger'daki izlerde (üç servis,
  son 24 saat) JWT, `Bearer`, `Authorization` ve `.env`'deki sekiz değerin araması.
- **Sonuç:** Cevaplarda yığın izi ya da iç ad yok. Loglarda 23 aramanın hepsi 0: gönderilen seviyelerle isteklerden sonra 18,
  şu anki container'ların açılışından bu yana 1.971 satır; ayrıntılı seviyede 483 ve 2.450 satır (27 Ekim koşusu). EF parametre değerlerini yazmıyor (`'?'`); servis başlarken ayarları yazan satır secret'ı yazmıyor; izlerde aramaların hepsi 0
  (`b-ek-kontroller.txt`).
  Bulgular: D2, D8.

### Girdi doğrulama ve veritabanı sorguları

- **Nasıl bakıldı:** istek modellerinin doğrulaması, sayfalama (canlıda taşma denemesi), arama; ham SQL için `3-ham-sql.ps1`;
  veritabanı kullanıcılarının yetkileri.
- **Sonuç:** Fatura isteği (müşteri kodu ≤ 64, para birimi `^[A-Z]{3}\z`, tutar > 0, en çok 2 ondalık, üst sınır), webhook alanları,
  takip notu (1–500), sayfa boyutu ve taşma (`page=2147483647` → 400), toplu yeniden gönderme (en çok 100) doğrulanıyor; aramada
  LIKE özel karakterleri kaçışlı. Ham SQL kullanılan 18 üretim yerinin hepsinde istekten gelen değer parametre olarak gidiyor
  ya da istekten değer gelmiyor (testlerdeki ham SQL saldırı yüzeyi olmadığı için dışarıda; son iki satır Gün 21'de O9 ile
  eklendi). Bulgular: D10, O9.

| Yer | Komut | Nasıl gösterildi |
|---|---|---|
| `InvoiceService.Infrastructure/Persistence/InvoiceStore.cs:14` | `SELECT nextval('invoice_number_seq')` | Logda; parametre yok, dizi adı koddaki sabit |
| `InvoiceStore.cs:87` | `SELECT * FROM invoices WHERE invoice_number = @p0 FOR UPDATE` | Logda, `[p0='?']` |
| `OperatorActionStore.cs:12` | `INSERT INTO operator_actions … VALUES (@p0 … @p5)` | Logda, 6 parametre |
| `OutboxStore.cs:16` | `WITH due AS (… WHERE status = @p0 …)` | Logda, 9 parametre |
| `OutboxStore.cs:84` | `INSERT INTO erp_outbox … ON CONFLICT …` | Koddan: `$"…{invoiceNumber}…"` (FormattableString; EF her değeri DbParameter yapar) |
| `PostgresSendPacer.cs:17` | `UPDATE erp_send_pace … make_interval(secs => @p0)` | Logda, 2 parametre |
| `ReconciliationStore.cs:27` | `UPDATE reconciliation_runs r SET status = @p0 …` | Logda, 6 parametre |
| `WebhookEventStore.cs:17` | `SET LOCAL lock_timeout = …; SET LOCAL statement_timeout = …` | Logda; `SET` parametre almaz, iki değer de ayardan doğrulanmış `int` |
| `WebhookEventStore.cs:21` | `INSERT INTO erp_webhook_events … VALUES (@p0 …)` | Logda, 8 parametre |
| `WebhookEventStore.cs:44` | `SELECT * FROM erp_webhook_events WHERE invoice_number = @p0 … FOR UPDATE` | Logda, 2 parametre |
| `WebhookEventStore.cs:53` | `UPDATE erp_webhook_events e SET … WHERE e.event_id = …` | Koddan: FormattableString |
| `AdvisoryReconciliationLock.cs:30` | `SELECT pg_try_advisory_lock(@key)` | Koddan: `NpgsqlCommand` + `Parameters.AddWithValue("key", Key)`, `Key` sabit |
| `ErpSimulator.Infrastructure/Persistence/ErpInvoiceStore.cs:13` | `SELECT pg_advisory_xact_lock(hashtextextended(…, 0))` | Koddan: `ExecuteSqlInterpolatedAsync` (FormattableString) |
| `Migrations/20261002161003_ProcessedAtOnlyWhenApplied.cs:14` | `UPDATE erp_webhook_events SET processed_at = NULL …` (DML) | Sabit metin, yalnız migration'da |
| `Migrations/20261008070347_AddErpSendPace.cs:14`, `:26` | `CREATE TABLE` / `DROP TABLE` (DDL) | Sabit metin, yalnız migration'da |
| `InvoiceService.Api/Startup/DatabaseMigrator.cs:71` | `CREATE ROLE` / `ALTER ROLE … PASSWORD` / `GRANT` (DDL) | Koddan: yalnız `--migrate-only` adımında; değerler istekten değil ayardan (`AppDatabaseUser`); kullanıcı adı `^[a-z_][a-z0-9_]*$` ile denetleniyor, şifre tırnakları kaçışlı literal (DDL parametre almaz) |
| `ErpSimulator.Api/Startup/DatabaseMigrator.cs:70` | aynı | aynı |

("Logda": `2-log-arama.ps1 -AyrintiliLog` koşusunun EF logunda komut metninde parametre adı var, değer yok.)

### Bağımlılıklardaki bilinen açıklar

- **Nasıl bakıldı:** `dotnet list package --vulnerable --include-transitive` (`InvoiceService.slnx`, `ErpSimulator.slnx`,
  `AlertReceiver.csproj`), `npm audit` ve `npm audit --omit=dev` (operations-ui), 27 Ekim 2026; imaj ve Actions sürümlerinin sabitlenmesi.
- **Sonuç:** .NET: 16 projenin hiçbirinde bilinen açıklı paket yok. Operasyon ekranı: üretim bağımlılıklarında 0, geliştirme
  bağımlılıklarında 2 moderate (D1). Sürüm sabitleme: D5. İmajların içindeki paketler için öneri: "Ek olarak bakılanlar".

### Ekranın HTTP güvenlik başlıkları

- **Nasıl bakıldı:** `nginx.conf`; canlıda `GET http://localhost:5100/` ve API'nin başlıkları.
- **Sonuç:** O4 (düzeltildi).

### Dışarıya açık portlar

- **Nasıl bakıldı:** compose'daki `ports:` satırları, `docker compose ps`; canlıda her porta yerel ağ adresinden bağlantı (önce/sonra).
- **Sonuç:** Y1 (düzeltildi). Collector'ların portları ve alert-receiver yayımlanmıyor.

## Ek olarak bakılanlar (OWASP Top 10:2025)

| Kategori | Nereye bakıldı | Bulgular |
|---|---|---|
| A01 Broken Access Control (SSRF dahil) | endpoint kuralları, kimliksiz uçlar, CORS; SSRF: dışarıya giden adresler yalnız ayardan (`Erp:BaseUrl`, `Webhooks:TargetUrl`), istekten URL alınmıyor | Y5, O3, O10, D2 |
| A02 Security Misconfiguration | compose, portlar, başlıklar, container kullanıcıları, veritabanı rolleri, Keycloak modu | K1, K2, Y1, O4, O9, D3, D4, D6 |
| A03 Software Supply Chain Failures | `dotnet list package`, `npm audit`, imaj ve Actions sürümleri | D1, D5 |
| A04 Cryptographic Failures | secret'ların saklanması, HMAC, TLS | Y2, O5 |
| A05 Injection | ham SQL (bulgu yok), LIKE kaçışı, log satırları, girdi doğrulama | D8, D10 |
| A06 Insecure Design | iş akışları: yeniden deneme, mutabakat, ERP'ye güven | Y5, O6, D9 |
| A07 Authentication Failures | Keycloak realm, token doğrulama, anahtar yenileme, şifreler | K1, K2, Y3, Y4, O1, O2, O7, D7 |
| A08 Software or Data Integrity Failures | webhook imzası, telemetri verisi | Y2, D11 |
| A09 Security Logging and Alerting Failures | Keycloak olay kaydı, API'nin 401/403 logu, alarm kuralları | O8, D8 |
| A10 Mishandling of Exceptional Conditions | hata yolları (`catch` blokları): JWT hataları reddediyor, Keycloak açılışta yoksa token reddediliyor, ayar hatasında servis açılmıyor, mutabakat okuma hatasında hiçbir şey değiştirmiyor, ERP cevabı okunamazsa "yok" sayılmıyor; açık kalan: Keycloak'a sonradan ulaşılamazken eski anahtar listesi kalıyor (Önce bir düzeltme, README) | D9 |

Diğer bileşenler: operasyon ekranında `dangerouslySetInnerHTML`, `innerHTML`, `eval` yok, sunucudan gelen bütün metin JSX ile
kaçışlı, bağlantılar `encodeURIComponent`'li, token yalnız bellekte; CSRF: API token'ı `Authorization` başlığında taşıyor, çerez
yok; Alertmanager ve simülatör `text/plain` POST'u 415 ile reddediyor; izleme ayarlarında ve alert-receiver'da secret yok;
Docker derleme bağlamına `.env` girmiyor.

Öneri: kendi ve üçüncü taraf imajların (Keycloak, PostgreSQL, Grafana, Prometheus, Alertmanager, Jaeger, Collector, nginx,
aspnet) içindeki paketler bilinen açıklar için düzenli olarak (ör. CI'da bir imaj tarayıcısıyla) taransın ve imajlar güncel sürümlerde tutulsun.
