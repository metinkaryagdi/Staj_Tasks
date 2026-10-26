// Fatura Servisi'nin tarayıcıdan görünen adresi. Derleme sırasında VITE_API_URL ile verilir (docker-compose.yml'deki
// build arg); verilmezse bilgisayarda çalışan servisin adresi kullanılır.
export const apiUrl: string = (import.meta.env.VITE_API_URL ?? 'http://localhost:5090').replace(/\/$/, '')

// Keycloak'ın tarayıcıdan görünen adresi. Derleme sırasında VITE_KEYCLOAK_URL ile verilir (docker-compose.yml'deki build
// arg); verilmezse bilgisayarda çalışan Keycloak'ın adresi kullanılır.
export const keycloakUrl: string = (import.meta.env.VITE_KEYCLOAK_URL ?? 'http://localhost:8080').replace(/\/$/, '')

// Kullanıcıların bulunduğu realm ve bu ekranın oradaki client'ı (keycloak/fatura-realm.json).
export const keycloakRealm = 'fatura'
export const keycloakClientId = 'operasyon-ekrani'

// Sayfalardaki verilerin kendiliğinden yenilenme aralığı.
export const refreshIntervalMs = 10_000

// Mutabakat çalışırken sonucunu çabuk görmek için daha sık yenilenir.
export const runningRefreshIntervalMs = 2_000

// Fatura Servisi bu süre içinde cevap vermezse ulaşılamıyor sayılır.
export const requestTimeoutMs = 15_000

// Kullanıcı bu kadar dakika hiçbir işlem yapmazsa (tıklama, tuş, kaydırma) oturum kapanır ve giriş sayfasına dönülür. Ekranın
// kendi yenilemeleri işlem sayılmaz. En az 2: uyarı süre dolmadan 1 dakika önce çıkar.
export const idleTimeoutMinutes = 15

// Süre dolmadan bu kadar önce uyarı çıkar; kullanıcı oturumu uzatabilir.
export const idleWarningMs = 60_000
