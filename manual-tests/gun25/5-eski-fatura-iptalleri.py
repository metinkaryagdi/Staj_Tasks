# Kontrol listesi 4 ve 5: geçiş koşusu bittikten sonra, koşunun veritabanlarından okur, hiçbir şey değiştirmez.
# ERP'ye v1 ile alınmış faturalardan, iptali yüzde 100'e geçtikten sonra (geri dönüş dakikası hariç) ya da v1 kapalıyken istenenlerin son durumu.
# Ayrıca yüzde değişiminden sonra eski sürüme ya da yeni sürüme giren son kaydın saniyesi.
#   python manual-tests/gun25/5-eski-fatura-iptalleri.py <invoice-db container> <erp-db container> <yüzde 100> <geri dönüş> <yeniden 100> <v1 kapalı>
# Zamanlar UTC, 'YYYY-MM-DD HH:MM:SS'.
import collections
import subprocess
import sys


def sql(container, user, database, query):
    out = subprocess.run(["docker", "exec", container, "psql", "-U", user, "-d", database, "-tAc", query],
                         capture_output=True, text=True, encoding="utf-8", check=True).stdout
    return [line.split("|") for line in out.splitlines() if line.strip()]


invoice_db, erp_db, moved, back, again, closed = sys.argv[1:7]
service = lambda q: sql(invoice_db, "invoice", "invoice_service", q)
erp = lambda q: sql(erp_db, "erp", "erp_simulator", q)

v1 = {row[0] for row in erp("SELECT DISTINCT invoice_number FROM invoices WHERE api_version = 1")}
cancelled_at_erp = {row[0] for row in erp("SELECT invoice_number FROM cancellations")}
events = collections.Counter()
for number, is_v2 in service("SELECT invoice_number, (payload::jsonb ? 'schema')::text FROM erp_webhook_events WHERE event_type = 'invoice.cancelled'"):
    if number in v1:
        events["yeni" if is_v2 == "true" else "eski"] += 1

rows = service(
    "SELECT o.invoice_number, o.created_at, o.status, i.status, (o.created_at >= '%s+00')::text, "
    "(o.created_at >= '%s+00' AND (o.created_at < '%s+00' OR o.created_at >= '%s+00'))::text "
    "FROM erp_outbox o JOIN invoices i USING (invoice_number) WHERE o.kind = 'İptal'" % (closed, moved, back, again))
windows = {"yüzde 100'de": collections.Counter(), "v1 kapalıyken": collections.Counter()}
for number, _, row_status, invoice_status, after_close, after_move in rows:
    if number not in v1:
        continue
    window = "v1 kapalıyken" if after_close == "true" else "yüzde 100'de" if after_move == "true" else None
    if window:
        windows[window][invoice_status] += 1
        windows[window]["toplam"] += 1
        windows[window]["ERP'de iptal kaydı"] += number in cancelled_at_erp
        windows[window]["iptal satırı " + row_status] += 1

for name, counts in windows.items():
    print(f"v1 ile gönderilmiş, iptali {name} istenen: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
print(f"v1 faturalarının invoice.cancelled haberleri: {dict(events)}")
first = erp(f"SELECT coalesce(extract(epoch FROM max(received_at) - '{moved}+00')::int::text, '-'), count(*) FROM invoices WHERE api_version = 1 AND received_at >= '{moved}+00' AND received_at < '{back}+00'")
print(f"Yüzde 100'e geçtikten sonra son v1 kaydı: {first[0][0]} sn sonra ({first[0][1]} kayıt)")
second = erp(f"SELECT coalesce(extract(epoch FROM max(received_at) - '{back}+00')::int::text, '-'), count(*) FROM invoices WHERE api_version = 2 AND received_at >= '{back}+00' AND received_at < '{again}+00'")
print(f"Geri dönüşten sonra son v2 kaydı: {second[0][0]} sn sonra ({second[0][1]} kayıt)")
runs = service("SELECT id, status, started_by, checked_count, fixed_count, reported_count FROM reconciliation_runs ORDER BY id")
print("Mutabakat çalışmaları (no, durum, başlatan, kontrol, düzeltilen, raporlanan):")
for run in runs:
    print("  " + ", ".join(run))
for row in service("SELECT run_id, finding_type, action, count(*) FROM reconciliation_findings GROUP BY 1, 2, 3 ORDER BY 1, 2"):
    print("  çalışma " + ", ".join(row))
