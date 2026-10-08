// Simülatöre doğrudan, saniyede RATE istek (varsayılan 50), DURATION boyunca (varsayılan 10s). Her istek farklı fatura
// numarasıyla (PREFIX + sıra). 429'lar cevabın başlığından ayrılır: hız sınırı ("Rate limit exceeded", Retry-After: 1
// olmalı) ve Meşgul davranışı ("ERP is busy").
import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';

const BASE = __ENV.ERP_URL || 'http://erp-simulator:8080';
const PREFIX = __ENV.PREFIX || 'RL-';

export const options = {
  scenarios: {
    rate_limit: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 50), timeUnit: '1s', duration: __ENV.DURATION || '10s',
      preAllocatedVUs: 50, maxVUs: 200,
    },
  },
  summaryTrendStats: ['min', 'med', 'p(95)', 'max'],
};

export default function () {
  const body = JSON.stringify({
    invoiceNumber: `${PREFIX}${exec.scenario.iterationInTest}`,
    customerCode: 'C-RL', amount: 10.5, currency: 'TRY', invoiceDate: '2026-10-08',
  });
  const res = http.post(`${BASE}/api/v1/invoices`, body, { headers: { 'Content-Type': 'application/json' } });
  const rateLimited = res.status === 429 && res.body.includes('Rate limit exceeded');
  const busy = res.status === 429 && res.body.includes('ERP is busy');
  check(res, {
    'kabul (202)': (r) => r.status === 202,
    'hız sınırı 429 (Rate limit exceeded)': () => rateLimited,
    'meşgul 429 (ERP is busy)': () => busy,
    'her 429 iki türden biri': (r) => r.status !== 429 || rateLimited || busy,
    'hız sınırı 429 cevabında Retry-After: 1': (r) => !rateLimited || r.headers['Retry-After'] === '1',
  });
}

// Kontrol sayıları PowerShell script'inin okuması için JSON olarak /out'a (manual-tests\output) yazılır.
export function handleSummary(data) {
  const checks = data.root_group.checks.map((c) => ({ name: c.name, passes: c.passes, fails: c.fails }));
  const lines = checks.map((c) => `  ${c.name}: ${c.passes} geçti, ${c.fails} kaldı`).join('\n');
  return {
    [`/out/${__ENV.SUMMARY_FILE || 'hiz-siniri-k6.json'}`]: JSON.stringify({ requests: data.metrics.http_reqs.values.count, duration: data.metrics.http_req_duration.values, checks }, null, 2),
    stdout: `k6: ${data.metrics.http_reqs.values.count} istek\n${lines}\n`,
  };
}
