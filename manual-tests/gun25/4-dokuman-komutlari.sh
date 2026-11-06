#!/usr/bin/env bash
# Kontrol listesi 7: ERP-GECIS.md'deki komutlar yazıldığı gibi çalışıyor mu. Yük yok. Repo kökünden, açık stack üzerinde çalışır.
#   bash manual-tests/gun25/4-dokuman-komutlari.sh
set -u
pw=$(grep '^TEST_OPERATOR_PASSWORD=' .env | cut -d= -f2 | tr -d '\r')
TOKEN=$(curl -s http://localhost:8080/realms/fatura/protocol/openid-connect/token -d grant_type=password -d client_id=fatura-test -d username=operator --data-urlencode "password=$pw" | python -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
put() { curl -s -w ' HTTP %{http_code}\n' -X PUT http://localhost:5090/api/v1/erp-version -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "{\"v2Percent\":$1}"; }
echo "--- Adım 1"; curl -s -w ' HTTP %{http_code}\n' http://localhost:5080/api/v2/invoices/YOK; curl -s -w ' HTTP %{http_code}\n' http://localhost:5090/api/v1/erp-version -H "Authorization: Bearer $TOKEN"
echo "--- Yüzde 10"; put 10
echo "--- Kontrol 1"; docker compose exec -T erp-db psql -U erp -d erp_simulator -c "SELECT api_version, count(*) FROM invoices WHERE received_at > now() - interval '1 minute' GROUP BY 1"
echo "--- Kontrol 2"; docker compose exec -T invoice-db psql -U invoice -d invoice_service -c "SELECT kind, status, count(*) FROM erp_outbox GROUP BY 1, 2 ORDER BY 1, 2"
docker compose exec -T invoice-db psql -U invoice -d invoice_service -c "SELECT left(last_error, 80), count(*) FROM erp_outbox WHERE status = 'Başarısız' AND last_error NOT LIKE 'Fatura iptal edildi%' AND last_error NOT LIKE '%Invoice rejected%' GROUP BY 1"
echo "--- Kontrol 3"; docker compose exec -T erp-db psql -U erp -d erp_simulator -c "SELECT invoice_number, count(*) FROM invoices GROUP BY 1 HAVING count(*) > 1"
echo "--- Yüzde 100"; put 100
echo "--- v1 kapatma"; Simulator__V1Enabled=false docker compose up -d erp-simulator 2>&1 | tail -1; sleep 8; curl -s -w ' HTTP %{http_code}\n' http://localhost:5080/api/v1/invoices/YOK
echo "--- Geri dönüş: v1 açılır"; Simulator__V1Enabled=true docker compose up -d erp-simulator 2>&1 | tail -1; sleep 8; curl -s -w ' HTTP %{http_code}\n' http://localhost:5080/api/v1/invoices/YOK
echo "--- Yüzde 0"; put 0
echo "--- Geçersiz yüzde"; put 101
