# Güvenlik Gözden Geçirmesi

Repodaki her şey kapsamdadır: Fatura Servisi, ERP Simülatörü, operasyon ekranı, Keycloak ayarları (`keycloak/`), docker compose
ve izleme bileşenleri (`monitoring/`, alert-receiver); ayrıca Dockerfile'lar, CI (`.github/`), yük testi ve script'ler.
Bulgular [OWASP Top 10:2025](https://top10.owasp.org/2025/) kategorileriyle eşleştirilmiştir.

## Yöntem

- **Saldırgan:** repodaki compose olduğu gibi çalıştırılmışken (1) aynı ağdaki herhangi bir makine, (2) repoyu okuyabilen
  biri. Repo GitHub'da public olduğu için (2) internetteki herkestir. Dereceler düzeltmeden önceki duruma göre verilmiştir.
- **Önem derecesi:** saldırganın açığı ne kadar kolay kullandığı ve etkisi:
  - **Kritik:** kimlik bilgisi gerekmeden ya da herkesin bildiği bilgiyle sistemin tamamı (kimlik sağlayıcı, veri) ele geçer.
  - **Yüksek:** faturaların durumu, verisi ya da yetkiler değiştirilebilir ya da doğrudan okunabilir.
  - **Orta:** etki sınırlı ya da başka bir açığın yanında anlam kazanır.
  - **Düşük:** bilgi sızıntısı, yalnız geliştirmede etkili olan ya da istismarı zor durumlar.
- **Kod incelemesi:** iki servisin, alert-receiver'ın ve operasyon ekranının bütün kaynak kodu (156 dosya, yaklaşık 10.400
  satır), ayar dosyaları, realm dosyası, compose, Dockerfile'lar, nginx ve izleme ayarları, CI, git geçmişi.
- **Canlı kontroller** (`manual-tests/gun20/`):
  - `1-canli-tarama.ps1`: portlara bilgisayarın yerel ağ adresinden bağlanır (bu adresten açılan bir port aynı ağdaki başka
    makineden de açılır), repodaki şifrelerle giriş dener, kimliksiz uçları ve sahte webhook'u dener, HTTP başlıklarını,
    CORS'u ve hata cevaplarını kontrol eder. Düzeltmeden önce ve sonra aynı script koşulmuştur.
  - `2-log-arama.ps1`: isteklerden sonraki loglarda ve şu anki container'ların açılışından bu yana bütün loglarda token, şifre
    ve secret arar (gönderilen log seviyeleriyle ve `-AyrintiliLog` ile).
  - `3-ham-sql.ps1`: ham SQL kullanılan her yeri bulur ve EF logunda parametreli gittiğini gösterir.
  - Keycloak yönetim API'sinden realm ayarlarının okunması, izleme araçlarına kimliksiz ve başka origin'den istekler.
- **Bağımlılık taraması:** `dotnet list package --vulnerable --include-transitive`, `npm audit`.
- **Bağımsız kontrol:** bulgular iki ayrı gözden geçirmeyle (biri dokümanı denetleyen, biri dokümanı okumadan bulgu arayan)
  karşılaştırıldı; bir bulgunun derecesi (Y5) ayrıca tarafsız bir değerlendirmeyle belirlendi.

## Özet

Bulgu numarasındaki harf önem derecesinin baş harfidir (K Kritik, Y Yüksek, O Orta, D Düşük), rakam o derecedeki sırasıdır.

| # | Önem | Bulgu | OWASP | Durum |
|---|---|---|---|---|
| K1 | Kritik | Keycloak yönetici hesabı `admin/admin`, Keycloak portu ağa açık | A07, A02 | Düzeltildi |
| K2 | Kritik | Veritabanı şifreleri repoda, veritabanı portları ağa açık | A07, A02 | Düzeltildi |
| Y1 | Yüksek | compose'daki bütün portlar bütün ağ arayüzlerine açık | A02 | Düzeltildi |
| Y2 | Yüksek | Webhook HMAC secret'ı repoda: sahte ERP haberiyle fatura durumu değiştirilebiliyor | A04, A08 | Düzeltildi |
| Y3 | Yüksek | Sipariş sistemi client secret'ı repoda: fatura oluşturma yetkili token alınabiliyor | A07 | Düzeltildi |
| Y4 | Yüksek | Test kullanıcılarının şifreleri repoda: operatör yetkisi alınabiliyor | A07 | Düzeltildi |
| Y5 | Yüksek | ERP Simülatörü'nün API'si kimlik doğrulaması istemiyor | A01, A06 | Düzeltildi (ağ erişimi); kalan risk Orta, öneri |
| O1 | Orta | Kaba kuvvet koruması ve şifre politikası yok; `admin-cli` şifreyle token veriyor | A07 | Öneri |
| O2 | Orta | Grafana yönetici hesabı imajın varsayılanı (`admin/admin`) | A07 | Öneri |
| O3 | Orta | Alertmanager, Prometheus ve Jaeger kimlik doğrulaması istemiyor | A01 | Öneri |
| O4 | Orta | Operasyon ekranında HTTP güvenlik başlıkları yok, nginx sürümü görünüyor | A02 | Öneri |
| O5 | Orta | Bütün trafik HTTP üzerinden (TLS yok) | A04 | Öneri |
| O6 | Orta | ERP'deki kayıt içeriği karşılaştırılmadan faturaya bağlanıyor | A06 | Öneri |
| O7 | Orta | Tarayıcı client'ı offline token alabiliyor; refresh token tekrar kullanılabiliyor | A07 | Öneri |
| O8 | Orta | Güvenlik olayları saklanmıyor ve izlenmiyor | A09 | Öneri |
| O9 | Orta | Uygulamaların veritabanı kullanıcıları süper kullanıcı | A02 | Öneri |
| O10 | Orta | Alertmanager ve Prometheus her web sitesine CORS izni veriyor | A01 | Öneri |
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
- **Öneri:** Şifreler realm dosyasında olmasın, içe aktarılırken ortamdan verilsin (Y3 ile aynı yol).
- **Düzeltme:** Realm dosyasında `${TEST_IZLEYICI_PASSWORD}`, `${TEST_OPERATOR_PASSWORD}`, `${TEST_ROLSUZ_PASSWORD}`; compose
  `.env`'deki değerleri Keycloak'a veriyor, testlerin Keycloak'ı kendi test değerlerini veriyor; script'ler şifreleri `.env`'den
  okuyor, `.http` dosyasında değer yok (`.env`'den elle kopyalanır).
- **Önce:** istek `POST http://localhost:8080/realms/fatura/protocol/openid-connect/token` (`grant_type=password`,
  `client_id=fatura-test`, realm dosyasındaki şifreler) → üç kullanıcının token'ı alındı; operator `fatura-operatoru`, izleyici
  `fatura-izleyici` rolüyle (`manual-tests/gun17/1-hazir.ps1`, `manual-tests/output/gun17/gun17-1-hazir.txt`).
- **Sonra:** aynı istek eski şifrelerle → üçünde 400 `invalid_grant` (`1-canli-tarama.ps1` B2, `c-canli-sonra.txt`); `.env`'deki
  şifrelerle token alınıyor (`2-log-arama.ps1`, `b-log-arama.txt`).

### Y5 — ERP Simülatörü'nün API'si kimlik doğrulaması istemiyor (Yüksek; ağ erişimi düzeltildi, kalan risk Orta)

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
- **Düzeltme:** Bulguyu Yüksek yapan, düzeltmeden önceki compose'da aynı ağdaki herkesin simülatöre ulaşabilmesiydi; port
  yalnız `127.0.0.1`'e açıldı (Y1).
- **Önce:** istek `GET http://<yerel ağ adresi>:5080/api/v1/invoices?from=…&to=…`, token'sız → 200 (`1-canli-tarama.ps1` C,
  `b-canli-once.txt`).
- **Sonra:** aynı istek → bağlantı kurulamıyor (C, `c-canli-sonra.txt`).
- **Kalan risk (Orta):** Uygulama katmanında kimlik doğrulaması hâlâ yok. Bu bilgisayardan ya da compose ağındaki bir
  container'dan simülatöre ulaşan biri yukarıdakilerin hepsini yapabilir; yani bulgu artık başka bir açığın (bu makineye ya da
  compose ağına erişim) yanında anlam kazanıyor.
- **Öneri:** Simülatör kimlik doğrulaması istesin (ör. `.env`'den gelen bir API anahtarı) ve Fatura Servisi bunu göndersin.
  Simülatör gerçek ERP'nin yerini tutuyor; gerçek ERP'ye geçildiğinde de Fatura Servisi'nin kimlik bilgisi göndermesi ve ERP
  cevabına içerik karşılaştırmadan güvenmemesi (O6) gerekir.

### O1 — Kaba kuvvet koruması ve şifre politikası yok; `admin-cli` şifreyle token veriyor (Orta)

- **Ne:** Realm'de `bruteForceProtected: false`, `passwordPolicy` boş. `fatura` realm'inin `admin-cli` client'ı public ve
  şifreyle token veriyor (`directAccessGrantsEnabled`).
- **Nerede:** `keycloak/fatura-realm.json` (realm ayarları), Keycloak varsayılanları.
- **Nasıl istismar edilir:** Bir hesabın şifresi sınırsız sayıda denenir; `admin-cli` ile giriş sayfasına uğramadan denenebilir
  (bu token'ın audience'ı olmadığı için API kabul etmez, ama doğru şifre öğrenilir).
- **Etki:** Zayıf şifreli bir hesabın ele geçmesi kolaylaşır.
- **Öneri:** `bruteForceProtected` ve bir şifre politikası açılsın; `fatura` realm'inde `admin-cli`'nin şifreyle token vermesi kapatılsın.

### O2 — Grafana yönetici hesabı imajın varsayılanı (Orta)

- **Ne:** Grafana'nın yönetici şifresi değiştirilmemiş (`admin/admin`); anonim kullanıcı panoyu görüyor.
- **Nerede:** `docker-compose.yml` (`grafana`; `GF_SECURITY_ADMIN_PASSWORD` yok).
- **Nasıl istismar edilir:** Grafana'ya ulaşabilen biri `admin/admin` ile girer.
- **Etki:** Pano ve veri kaynağı değiştirilir; Prometheus'taki metrikler okunur. Uygulama verisine yazma yok.
- **Öneri:** `GF_SECURITY_ADMIN_PASSWORD` ortamdan verilsin.

### O3 — Alertmanager, Prometheus ve Jaeger kimlik doğrulaması istemiyor (Orta)

- **Ne:** Üçünün de arayüzü ve API'si kimliksiz.
- **Nerede:** `docker-compose.yml`, `monitoring/`.
- **Nasıl istismar edilir:** Alertmanager'a `POST /api/v2/silences` ile alarmları susturan bir kayıt yazılır; Prometheus'tan
  ayarlar ve metrikler, Jaeger'dan fatura numaralı izler okunur.
- **Etki:** Bir saldırı sırasında alarmlar sessizce kapatılabilir; iç yapı ve fatura numaraları okunur.
- **Öneri:** Dışarıya açılacaksa önlerine kimlik doğrulayan bir reverse proxy konsun.

### O4 — Operasyon ekranında HTTP güvenlik başlıkları yok (Orta)

- **Ne:** `Content-Security-Policy`, `X-Frame-Options` (ya da `frame-ancestors`), `X-Content-Type-Options`, `Referrer-Policy`,
  `Permissions-Policy` yok; `Server: nginx/1.31.8` sürüm bilgisi veriyor; API'nin cevabında da `Server` başlığı var (Kestrel varsayılanı).
- **Nerede:** `operations-ui/nginx.conf`, Kestrel varsayılanı.
- **Nasıl istismar edilir:** Ekran başka bir sitenin içine iframe ile gömülüp operatöre "Yeniden gönder"e tıklatılır
  (clickjacking); bir XSS olursa CSP onu sınırlamaz.
- **Etki:** Operatörün haberi olmadan müdahale; XSS durumunda bellekteki token'ın okunması.
- **Öneri:** nginx'e `Content-Security-Policy` (`default-src 'self'`, `connect-src` API ve Keycloak, `frame-ancestors 'none'`),
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`; `server_tokens off`; Kestrel'de `AddServerHeader = false`.

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

### O7 — Tarayıcı client'ı offline token alabiliyor; refresh token tekrar kullanılabiliyor (Orta)

- **Ne:** `offline_access` varsayılan rollerde ve `operasyon-ekrani`'nın isteğe bağlı scope'larında; offline oturum 30 gün boşta
  kalabiliyor, en uzun süre sınırı kapalı; `revokeRefreshToken: false`.
- **Nerede:** Keycloak realm varsayılanları (`keycloak/fatura-realm.json`'da ayarlanmamış).
- **Nasıl istismar edilir:** Kullanıcı (ya da tarayıcısında kod çalıştıran biri) `scope=openid offline_access` ile offline
  refresh token alır.
- **Etki:** Bu token SSO süreleri, ekranın 15 dk işlemsizlik kapanması ve çıkıştan bağımsız; çalınırsa uzun ömürlü kimlik bilgisi olur.
- **Öneri:** `offline_access` varsayılan rollerden ve ekranın scope'larından çıkarılsın; offline oturuma en uzun süre ve
  `revokeRefreshToken` açılsın.

### O8 — Güvenlik olayları saklanmıyor ve izlenmiyor (Orta)

- **Ne:** Keycloak'ta `eventsEnabled` ve `adminEventsEnabled` kapalı: başarısız girişler yalnız container loguna yazılıyor
  (`jboss-logging`, `LOGIN_ERROR`), olaylar saklanmıyor, yönetici değişiklikleri kaydedilmiyor. Fatura Servisi'nin 401/403
  cevapları gönderilen log seviyesinde yazılmıyor, metrik ve alarm yok (alarm yalnız webhook 401'i için).
- **Nerede:** realm, `invoice-service/.../appsettings.json` (`Microsoft.AspNetCore: Warning`), `monitoring/prometheus/alert-rules.yml`.
- **Nasıl istismar edilir:** Çalıntı ya da bozuk token'la ve yetkisiz müdahale denemeleri API'de iz bırakmaz; şifre denemeleri
  yalnız Keycloak'ın container logunda kalır, olay olarak sorgulanamaz; yönetici değişiklikleri kaydedilmez.
- **Etki:** Saldırı fark edilmez, sonradan incelenemez.
- **Öneri:** Keycloak olay kaydı açılsın; serviste 401/403 için bir log satırı ve metrik, yoğunlaşınca alarm.

### O9 — Uygulamaların veritabanı kullanıcıları süper kullanıcı (Orta)

- **Ne:** `invoice` ve `erp` kullanıcıları `rolsuper=t` (resmi PostgreSQL imajında `POSTGRES_USER` süper kullanıcı olur).
- **Nerede:** `docker-compose.yml`, bağlantı dizeleri.
- **Nasıl istismar edilir:** Bir SQL enjeksiyonu (bulunmadı) ya da sızan bağlantı bilgisiyle bütün veritabanı ve
  `COPY … TO PROGRAM` ile veritabanı container'ında komut çalıştırma.
- **Etki:** Başka bir açığın etkisini en üst düzeye çıkarır.
- **Öneri:** Migration için yönetici kullanıcı, uygulama için yalnız gereken tablolarda yetkisi olan ayrı bir kullanıcı.

### O10 — Alertmanager ve Prometheus her web sitesine CORS izni veriyor (Orta)

- **Ne:** Alertmanager `Access-Control-Allow-Origin: *` ve preflight'ta `POST` + `content-type` izni; Prometheus
  `--web.cors.origin=.*` (varsayılan) ile her origin'i yansıtıyor.
- **Nerede:** `docker-compose.yml` (iki servisin CORS ayarı yok).
- **Nasıl istismar edilir:** Yığın çalışırken geliştiricinin ya da operatörün tarayıcısında açılan herhangi bir sayfa
  `localhost:9093`'e alarm susturma yazar, `localhost:9090`'dan metrik ve ayar okur. Port daraltması (Y1) bunu engellemez:
  isteği kurbanın tarayıcısı atar.
- **Etki:** Alarmların uzaktan susturulması; metriklerin okunması.
- **Öneri:** Prometheus'a `--web.cors.origin` ile yalnız Grafana; Alertmanager'ın önüne kimlik doğrulayan bir proxy (O3).

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
- **Nasıl istismar edilir:** Bu bilgisayardan giriş sayfasına uğramadan, şifre denenip API'nin kabul ettiği token alınır.
- **Etki:** O1 ve Y4 ile birlikte şifre denemesini kolaylaştırır.
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
  kaldırılan bir anahtarın en kötü durumdaki kabul süresi hesabıyla README'de (Kimlik doğrulama, Gün 20).

### Webhook imzası

- **Nasıl bakıldı:** `WebhookSignature.cs`, `WebhookEndpoints.cs`, `WebhookRequestReader.cs`; canlıda doğru, yanlış ve sahte imzalı istek.
- **Sonuç:** Doğrulamada bulgu yok: imza zaman damgasını kapsıyor, karşılaştırma sabit sürede (`FixedTimeEquals`), 300 sn'den eski
  ya da ileri zaman damgası 401, gövde imzadan önce 64 KB ile sınırlı, iki kez gönderilen başlık geçersiz, aynı `event_id` ikinci
  kez uygulanmıyor, gövde imza doğrulanmadan işlenmiyor, 401 cevabı nedeni söylemiyor. Bulgular: Y2 (anahtarın saklandığı yer), D8.

### CORS

- **Nasıl bakıldı:** `CorsExtensions.cs`, ayar; canlıda Fatura Servisi'ne üç preflight; izleme araçlarına ve simülatöre başka origin'den istek.
- **Sonuç:** Fatura Servisi'nde bulgu yok: tek origin `http://localhost:5100`; `*`, yol içeren ya da geçersiz origin servis açılırken
  reddediliyor; yalnız `GET`/`POST` ve `Content-Type`, `Authorization`; credentials kapalı; `http://kotu-site.example` ve `null`
  origin'e izin dönmüyor. Bulgu: O10 (Alertmanager, Prometheus). Keycloak'ın discovery belgesinin CORS'u açık, ama belge herkese açık.

### Kodda ve ayar dosyalarında duran şifre ve secret'lar

- **Nasıl bakıldı:** ayar dosyaları, compose, realm dosyası, script'ler, `.http` dosyaları; git geçmişinde (`git log --all -p`) özel
  anahtar, GitHub/AWS token biçimleri, `secret`, `password`, `Password=` araması.
- **Sonuç:** Geçmişte yalnız "dev-only" değerler ve test şifreleri var, gerçek bir anahtar yok. K1, K2, Y2, Y3, Y4'in değerleri
  `.env`'e taşındı; eski değerler geçmişte duruyor, `1-canli-tarama.ps1` B2'de bu kurulumda geçersiz oldukları görüldü. Repoda
  kalan: O2 (Grafana imajının varsayılanı); eski ve artık geçersiz değerler ERP Simülatörü'nün birim testlerinin sabitlerinde
  (`WebhookPlannerTests.cs:21`, `:132`, `WebhookSenderTests.cs:14`), `AdvisoryReconciliationLockTests.cs:8` (`Password=invoice`,
  testin kendi container'ı) ve eski değerlerin reddedildiğini sınayan `1-canli-tarama.ps1`'de (bilerek).

### Hata mesajlarında ve loglarda dışarı sızan bilgi

- **Nasıl bakıldı:** `UseExceptionHandler` + ProblemDetails, log satırları ve formatlayıcı; canlıda bozuk JSON, 5000 karakterlik
  fatura numarası, simülatöre bozuk JSON. `2-log-arama.ps1`: token'lı (sipariş sistemi ve üç kullanıcı), token'sız, imzası bozuk,
  Basic şifreli istekler, Keycloak'a yanlış şifreyle giriş, imzalı ve yanlış imzalı webhook; sonra bütün container'ların
  isteklerden sonraki loglarında ve şu anki container'ların açılışından bu yana bütün loglarında (realm içe aktarma, yönetici hesabının oluşturulması,
  servislerin ayar satırları dahil) 23 arama: o koşuda alınan token'lar ve imza kısımları, her JWT biçimi, `Bearer` + değer, `Authorization`, `.env`'deki sekiz
  değerin her biri kendi değeriyle (iki veritabanı şifresi, Keycloak yönetici şifresi, webhook ve client secret'ı, üç test
  kullanıcısının şifresi), yanlış girilen şifre, Basic kimlik bilgisi, `Password=`, `client_secret=`. Jaeger'daki izlerde token,
  `Authorization` ve secret araması.
- **Sonuç:** Cevaplarda yığın izi ya da iç ad yok. Loglarda 23 aramanın hepsi 0: gönderilen seviyelerle isteklerden sonra 18,
  açılıştan bu yana 1.971 satır; ayrıntılı seviyede 483 ve 2.450 satır (27 Ekim koşusu). EF parametre değerlerini yazmıyor (`'?'`); servis başlarken ayarları yazan satır secret'ı yazmıyor; izlerde token yok.
  Bulgular: D2, D8.

### Girdi doğrulama ve veritabanı sorguları

- **Nasıl bakıldı:** istek modellerinin doğrulaması, sayfalama (canlıda taşma denemesi), arama; ham SQL için `3-ham-sql.ps1`;
  veritabanı kullanıcılarının yetkileri.
- **Sonuç:** Fatura isteği (müşteri kodu ≤ 64, para birimi `^[A-Z]{3}\z`, tutar > 0, en çok 2 ondalık, üst sınır), webhook alanları,
  takip notu (1–500), sayfa boyutu ve taşma (`page=2147483647` → 400), toplu yeniden gönderme (en çok 100) doğrulanıyor; aramada
  LIKE özel karakterleri kaçışlı. Ham SQL kullanılan 16 üretim yerinin hepsinde istekten gelen değer parametre olarak gidiyor
  (testlerdeki ham SQL saldırı yüzeyi olmadığı için dışarıda). Bulgular: D10, O9.

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

("Logda": `2-log-arama.ps1 -AyrintiliLog` koşusunun EF logunda komut metninde parametre adı var, değer yok.)

### Bağımlılıklardaki bilinen açıklar

- **Nasıl bakıldı:** `dotnet list package --vulnerable --include-transitive` (`InvoiceService.slnx`, `ErpSimulator.slnx`,
  `AlertReceiver.csproj`), `npm audit` ve `npm audit --omit=dev` (operations-ui), 27 Ekim 2026; imaj ve Actions sürümlerinin sabitlenmesi.
- **Sonuç:** .NET: 16 projenin hiçbirinde bilinen açıklı paket yok. Operasyon ekranı: üretim bağımlılıklarında 0, geliştirme
  bağımlılıklarında 2 moderate (D1). Sürüm sabitleme: D5. İmajların içindeki paketler için öneri: "Ek olarak bakılanlar".

### Ekranın HTTP güvenlik başlıkları

- **Nasıl bakıldı:** `nginx.conf`; canlıda `GET http://localhost:5100/` ve API'nin başlıkları.
- **Sonuç:** O4.

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
| A10 Mishandling of Exceptional Conditions | hata yolları (43 `catch`): JWT hataları reddediyor, Keycloak açılışta yoksa token reddediliyor, ayar hatasında servis açılmıyor, mutabakat okuma hatasında hiçbir şey değiştirmiyor, ERP cevabı okunamazsa "yok" sayılmıyor; açık kalan: Keycloak'a sonradan ulaşılamazken eski anahtar listesi kalıyor (Önce bir düzeltme, README) | D9 |

Diğer bileşenler: operasyon ekranında `dangerouslySetInnerHTML`, `innerHTML`, `eval` yok, sunucudan gelen bütün metin JSX ile
kaçışlı, bağlantılar `encodeURIComponent`'li, token yalnız bellekte; CSRF: API token'ı `Authorization` başlığında taşıyor, çerez
yok; Alertmanager ve simülatör `text/plain` POST'u 415 ile reddediyor; izleme ayarlarında ve alert-receiver'da secret yok;
Docker derleme bağlamına `.env` girmiyor.

Öneri: kendi ve üçüncü taraf imajların (Keycloak, PostgreSQL, Grafana, Prometheus, Alertmanager, Jaeger, Collector, nginx,
aspnet) içindeki paketler bilinen açıklar için düzenli olarak (ör. CI'da bir imaj tarayıcısıyla) taransın ve imajlar güncel sürümlerde tutulsun.
