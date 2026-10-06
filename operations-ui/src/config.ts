// Fatura Servisi'nin tarayıcıdan görünen adresi. Derleme sırasında VITE_API_URL ile verilir (docker-compose.yml'deki
// build arg); verilmezse bilgisayarda çalışan servisin adresi kullanılır.
export const apiUrl: string = (import.meta.env.VITE_API_URL ?? 'http://localhost:5090').replace(/\/$/, '')

// Sayfalardaki verilerin kendiliğinden yenilenme aralığı.
export const refreshIntervalMs = 10_000

// Mutabakat çalışırken sonucunu çabuk görmek için daha sık yenilenir.
export const runningRefreshIntervalMs = 2_000

// Fatura Servisi bu süre içinde cevap vermezse ulaşılamıyor sayılır.
export const requestTimeoutMs = 15_000
