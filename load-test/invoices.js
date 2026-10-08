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
// Sonuç ekrana ve load-test/results/<RUN_ID>.json'a yazılır: istek sayısı, POST /api/v1/invoices cevap süresinin
// p50/p95/p99'u, ilk ve son isteğin zamanı. p95 200 ms'yi geçerse k6 hata koduyla biter.
import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';

const BASES = (__ENV.BASE_URLS || 'http://invoice-service:8080').split(',');
const RATE = Number(__ENV.RATE || 50);
const DURATION = __ENV.DURATION || '5m';

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
    'http_req_duration': ['p(95)<200'],
  },
  summaryTrendStats: ['min', 'med', 'p(95)', 'p(99)', 'max'],
};

export function setup() {
  return { runId: __ENV.RUN_ID || `LOAD-${new Date().toISOString().replace(/[-:]/g, '').slice(0, 15)}`, startedAt: new Date().toISOString() };
}

export default function (data) {
  const base = BASES[exec.scenario.iterationInTest % BASES.length];
  const body = JSON.stringify({ customerCode: data.runId, amount: 100.5, currency: 'TRY', invoiceDate: '2026-10-08' });
  const res = http.post(`${base}/api/v1/invoices`, body, { headers: { 'Content-Type': 'application/json' } });
  check(res, { 'fatura alındı (202)': (r) => r.status === 202 });
}

export function handleSummary(data) {
  const runId = data.setup_data.runId;
  const d = data.metrics.http_req_duration.values;
  const accepted = data.root_group.checks[0];
  const result = {
    runId,
    baseUrls: BASES,
    rate: RATE,
    duration: DURATION,
    startedAt: data.setup_data.startedAt,
    finishedAt: new Date().toISOString(),
    requests: data.metrics.http_reqs.values.count,
    accepted: accepted.passes,
    notAccepted: accepted.fails,
    durationMs: { p50: d.med, p95: d['p(95)'], p99: d['p(99)'], min: d.min, max: d.max },
    p95Under200: d['p(95)'] < 200,
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
      `Sonuç dosyası: load-test/results/${runId}.json\n`,
  };
}
