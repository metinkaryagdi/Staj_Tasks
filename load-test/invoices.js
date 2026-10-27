// Fatura Servisi yük testi: dakikada 3000 fatura (saniyede 50), 5 dakika boyunca, toplam 15.000 fatura.
//
// Çalıştırma (repo kökünden, k6 kurmadan, compose'un ağında):
//   docker compose run --rm k6
//
// Ortam değişkenleriyle değiştirilebilir (verilmezse yukarıdaki değerler):
//   BASE_URLS  virgülle ayrılmış servis adresleri; birden fazlaysa istekler sırayla dağıtılır (iki kopya için
//              "http://invoice-service:8080,http://invoice-service-2:8080").
//   RATE       saniyedeki fatura sayısı.   DURATION   süre (k6 biçimi: 5m, 30s).
//   RUN_ID     faturaların müşteri kodu; verilmezse "LOAD-<başlangıç zamanı>". Ölçümler faturaları bununla bulur.
//
// İstekler sipariş sisteminin token'ıyla gider (Keycloak, client credentials); her VU token'ı bitmeden yeniler. Token ömrü
// 5 dakika: yenilemeyi görmek için süreyi uzatın (DURATION=7m).
//
// Sonuç ekrana ve load-test/results/<RUN_ID>.json'a yazılır: istek sayısı, POST /api/v1/invoices cevap süresinin
// p50/p95/p99'u, ilk ve son isteğin zamanı, alınan token ve 401 alan istek sayısı. p95 200 ms'yi geçerse k6 hata koduyla
// biter.
import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';
import { Counter } from 'k6/metrics';

const BASES = (__ENV.BASE_URLS || 'http://invoice-service:8080').split(',');
const RATE = Number(__ENV.RATE || 50);
const DURATION = __ENV.DURATION || '5m';
// constant-arrival-rate sürenin tam sonunda bazen bir iterasyon fazla başlatır; RATE × süreden fazlası istek göndermez.
const TOTAL = RATE * Number(DURATION.slice(0, -1)) * (DURATION.endsWith('m') ? 60 : 1);

// Faturayı yalnızca sipariş sistemi oluşturabilir: token'ı onun client'ıyla alınır (keycloak/fatura-realm.json).
const TOKEN_URL = 'http://keycloak:8080/realms/fatura/protocol/openid-connect/token';
// Secret'ı docker-compose.yml .env'den verir (ORDER_SYSTEM_CLIENT_SECRET); repoda tutulmaz.
const CLIENT_SECRET = __ENV.ORDER_SYSTEM_CLIENT_SECRET;
// Token bitmeden bu kadar saniye önce yenisi alınır; süresi dolmuş token'la istek gitmesin.
const RENEW_BEFORE_SECONDS = 30;

const tokensFetched = new Counter('tokens_fetched');
const unauthorized = new Counter('unauthorized_401');

// Her VU'nun kendi token'ı: k6'da bu değişkenler VU başınadır.
let token = null;
let renewAtMs = 0;

function orderSystemToken() {
  if (token && Date.now() < renewAtMs) return token;
  const res = http.post(TOKEN_URL, { grant_type: 'client_credentials', client_id: 'siparis-sistemi', client_secret: CLIENT_SECRET });
  const body = res.json();
  token = body.access_token;
  renewAtMs = Date.now() + (body.expires_in - RENEW_BEFORE_SECONDS) * 1000;
  tokensFetched.add(1);
  return token;
}

export const options = {
  scenarios: {
    invoices: {
      // Cevap süresinden bağımsız olarak saniyede RATE istek başlatır; cevap yavaşlarsa VU ekler.
      executor: 'constant-arrival-rate',
      rate: RATE, timeUnit: '1s', duration: DURATION,
      preAllocatedVUs: 50, maxVUs: 300,
    },
  },
  thresholds: {
    // Yalnızca fatura istekleri (endpoint:invoices); token istekleri ölçüme karışmaz.
    'http_req_duration{endpoint:invoices}': ['p(95)<200'],
  },
  summaryTrendStats: ['min', 'med', 'p(95)', 'p(99)', 'max'],
};

export function setup() {
  return { runId: __ENV.RUN_ID || `LOAD-${new Date().toISOString().replace(/[-:]/g, '').slice(0, 15)}`, startedAt: new Date().toISOString() };
}

export default function (data) {
  if (exec.scenario.iterationInTest >= TOTAL) return;
  const base = BASES[exec.scenario.iterationInTest % BASES.length];
  const body = JSON.stringify({ customerCode: data.runId, amount: 100.5, currency: 'TRY', invoiceDate: '2026-10-08' });
  const res = http.post(`${base}/api/v1/invoices`, body, {
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${orderSystemToken()}` },
    tags: { endpoint: 'invoices' },
  });
  check(res, { 'fatura alındı (202)': (r) => r.status === 202 });
  // Her istekte 0 ya da 1: hiç 401 olmasa da sayaç özette 0 olarak görünür.
  unauthorized.add(res.status === 401 ? 1 : 0);
}

export function handleSummary(data) {
  const runId = data.setup_data.runId;
  const d = data.metrics['http_req_duration{endpoint:invoices}'].values;
  const accepted = data.root_group.checks[0];
  const result = {
    runId,
    baseUrls: BASES,
    rate: RATE,
    duration: DURATION,
    startedAt: data.setup_data.startedAt,
    finishedAt: new Date().toISOString(),
    // Fatura istekleri: her birinin tek bir "fatura alındı" kontrolü var (token istekleri sayılmaz).
    requests: accepted.passes + accepted.fails,
    accepted: accepted.passes,
    notAccepted: accepted.fails,
    durationMs: { p50: d.med, p95: d['p(95)'], p99: d['p(99)'], min: d.min, max: d.max },
    p95Under200: d['p(95)'] < 200,
    // Her VU kendi token'ını alır: token sayısı VU sayısından büyükse token'lar yenilenmiştir.
    vusMax: data.metrics.vus_max.values.max,
    tokensFetched: data.metrics.tokens_fetched.values.count,
    unauthorized401: data.metrics.unauthorized_401.values.count,
  };
  const ms = (v) => `${v.toFixed(1)} ms`;
  return {
    [`/results/${runId}.json`]: JSON.stringify(result, null, 2),
    stdout:
      `\nYük testi ${runId}: ${result.requests} istek (${RATE}/sn, ${DURATION}), ${result.accepted} kabul (202), ` +
      `${result.notAccepted} başka\n` +
      `POST /api/v1/invoices cevap süresi: p50 ${ms(d.med)}, p95 ${ms(d['p(95)'])}, p99 ${ms(d['p(99)'])} ` +
      `(en kısa ${ms(d.min)}, en uzun ${ms(d.max)})\n` +
      `p95 < 200 ms: ${result.p95Under200 ? 'evet' : 'HAYIR'}\n` +
      `VU: ${result.vusMax}, alınan token: ${result.tokensFetched}, 401 alan istek: ${result.unauthorized401}\n` +
      `Sonuç dosyası: load-test/results/${runId}.json\n`,
  };
}
