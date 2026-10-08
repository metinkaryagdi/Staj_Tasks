// Fatura Servisi'ne saniyede RATE fatura (POST /api/v1/invoices), DURATION boyunca. BASE_URLS virgülle ayrılmış birden
// fazla adres olabilir: istekler sırayla dağıtılır (iki kopya). Faturalar CUSTOMER müşteri koduyla işaretlenir.
import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';

const BASES = (__ENV.BASE_URLS || 'http://invoice-service:8080').split(',');
const CUSTOMER = __ENV.CUSTOMER || 'LOAD';

export const options = {
  scenarios: {
    invoices: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 50), timeUnit: '1s', duration: __ENV.DURATION || '10s',
      preAllocatedVUs: 50, maxVUs: 200,
    },
  },
  summaryTrendStats: ['min', 'med', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const base = BASES[exec.scenario.iterationInTest % BASES.length];
  const body = JSON.stringify({ customerCode: CUSTOMER, amount: 100.5, currency: 'TRY', invoiceDate: '2026-10-08' });
  const res = http.post(`${base}/api/v1/invoices`, body, { headers: { 'Content-Type': 'application/json' } });
  check(res, { 'fatura alındı (202)': (r) => r.status === 202 });
}

export function handleSummary(data) {
  const checks = data.root_group.checks.map((c) => ({ name: c.name, passes: c.passes, fails: c.fails }));
  const d = data.metrics.http_req_duration.values;
  return {
    [`/out/${__ENV.SUMMARY_FILE || 'fatura-gonder-k6.json'}`]:
      JSON.stringify({ requests: data.metrics.http_reqs.values.count, duration: d, checks }, null, 2),
    stdout: `k6: ${data.metrics.http_reqs.values.count} istek, ${checks[0].passes} kabul (202), ${checks[0].fails} başka; ` +
      `cevap süresi medyan ${d.med.toFixed(1)} ms, p95 ${d['p(95)'].toFixed(1)} ms, en çok ${d.max.toFixed(1)} ms\n`,
  };
}
