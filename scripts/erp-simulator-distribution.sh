#!/usr/bin/env bash
# Measures the ERP Simulator's behavior distribution end to end over HTTP.
#
# - Recreates the simulator with LateResponseDelaySeconds=0 (rates unchanged) so N requests finish quickly.
# - Sends N invoices sequentially from a single curl process over one connection.
# - Counts behaviors from the simulator log, compares them to the configured rates (chi-square),
#   checks that each behavior is independent of the previous one, and cross-checks the counts
#   against the HTTP status codes and the database rows.
# - If the .NET SDK is installed, replays the seed offline (scripts/erp-simulator-replay.cs) and checks
#   that the logged sequence is identical, decision by decision.
# - Restores the simulator to the settings in appsettings.json when done.
#
# Usage: ./scripts/erp-simulator-distribution.sh [count=20000] [seed=from appsettings.json]

set -uo pipefail
cd "$(dirname "$0")/.."

COUNT="${1:-20000}"
SEED="${2:-}"
BASE_URL="http://localhost:5080"
PREFIX="DIST-$(date +%Y%m%d%H%M%S)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

wait_healthy() {
  for _ in $(seq 1 60); do curl -sf "$BASE_URL/health" >/dev/null && return 0; sleep 1; done
  echo "Simulator did not become healthy" >&2; exit 1
}

docker compose up -d --build >/dev/null 2>&1 || { echo "docker compose up failed" >&2; exit 1; }

overrides=(Simulator__LateResponseDelaySeconds=0)
[[ -n "$SEED" ]] && overrides+=("Simulator__Seed=$SEED")
env "${overrides[@]}" docker compose up -d --force-recreate erp-simulator >/dev/null 2>&1
wait_healthy

settings="$(docker compose logs erp-simulator --no-log-prefix | grep -m1 'Simulator settings:')"
echo "$settings" | sed 's/.*Simulator settings: /Settings: /'

# One curl process with URL globbing sends N sequential requests over a single kept-alive connection.
# (A new connection per request exhausts ephemeral ports on Windows at this volume and silently drops requests.)
# Every request uses the same invoice number: the simulator accepts duplicates, and it keeps this run's
# rows and log lines easy to select. The ?n= query only makes the URLs distinct; the API ignores it.
body="{\"invoiceNumber\":\"$PREFIX\",\"customerCode\":\"C-001\",\"amount\":10,\"currency\":\"TRY\",\"invoiceDate\":\"2026-09-29\"}"

echo "Sending $COUNT requests..."
start=$(date +%s)
curl -s -H 'Content-Type: application/json' -d "$body" -o /dev/null -w '%{http_code}\n' \
  "$BASE_URL/api/v1/invoices?n=[1-$COUNT]" > "$WORK/status.txt"
echo "Done in $(( $(date +%s) - start ))s"

# "<sequence> <behavior>" sorted by sequence (= RNG draw order), only this run's invoices.
docker compose logs erp-simulator --no-log-prefix \
  | grep "invoice=$PREFIX " \
  | sed -E 's/.*ERP request #([0-9]+) .* behavior=([A-Za-z]+).*/\1 \2/' \
  | sort -n > "$WORK/decisions.txt"

docker compose exec -T erp-db psql -U erp -d erp_simulator -tA -F' ' -c \
  "SELECT behavior, count(*) FROM invoices WHERE invoice_number = '$PREFIX' GROUP BY behavior;" \
  | tr -d '\r' > "$WORK/db.txt"

# Rates as configured, parsed from the startup log line.
rate() { echo "$settings" | grep -oE "$1=[0-9.]+%" | grep -oE '[0-9.]+'; }

awk -v n_sent="$COUNT" \
    -v rSuccess="$(rate success)" -v rBusy="$(rate busy)" -v rServerError="$(rate serverError)" \
    -v rSaveThenError="$(rate saveThenError)" -v rLateResponse="$(rate lateResponse)" \
    -v statusFile="$WORK/status.txt" -v dbFile="$WORK/db.txt" '
BEGIN {
  split("Success Busy ServerError SaveThenError LateResponse", names, " ")
  target["Success"] = rSuccess; target["Busy"] = rBusy; target["ServerError"] = rServerError
  target["SaveThenError"] = rSaveThenError; target["LateResponse"] = rLateResponse
  saves["Success"] = 1; saves["LateResponse"] = 1; saves["SaveThenError"] = 1
  crit[1] = 3.84; crit[2] = 5.99; crit[3] = 7.81; crit[4] = 9.49
  while ((getline line < statusFile) > 0) http[line]++
  while ((getline line < dbFile) > 0) { split(line, f, " "); db[f[1]] = f[2] }
}
{ count[$2]++; n++; if (n > 1) { from[prev]++; pair[prev, $2]++ } prev = $2 }
END {
  printf "\nLogged decisions: %d / %d sent\n\n", n, n_sent
  printf "%-14s %8s %9s %8s\n", "Behavior", "Target", "Observed", "Count"
  df = -1
  for (i = 1; i <= 5; i++) {
    b = names[i]; expected = n * target[b] / 100
    printf "%-14s %7.2f%% %8.2f%% %8d\n", b, target[b], (n ? 100 * count[b] / n : 0), count[b]
    if (expected > 0) { chi += (count[b] - expected) ^ 2 / expected; df++ }
    else if (count[b] > 0) unexpected = 1
  }
  if (df >= 1) {
    ok = chi < crit[df] && !unexpected
    printf "\nChi-square = %.2f (df %d, 5%% critical value %.2f) -> %s\n", chi, df, crit[df], ok ? "PASS" : "FAIL"
  } else ok = !unexpected

  printf "\nIndependence: share of each next behavior, by previous behavior\n%-14s", "prev \\ next"
  for (j = 1; j <= 5; j++) printf " %13s", names[j]
  printf "\n"
  for (i = 1; i <= 5; i++) {
    a = names[i]; if (!from[a]) continue
    printf "%-14s", a
    for (j = 1; j <= 5; j++) printf " %12.1f%%", 100 * pair[a, names[j]] / from[a]
    printf "\n"
  }

  e202 = count["Success"] + count["LateResponse"]; e429 = count["Busy"]
  e500 = count["ServerError"] + count["SaveThenError"]
  httpOk = http["202"] == e202 && http["429"] == e429 && http["500"] == e500 && n == n_sent
  printf "\nCross-check HTTP : 202=%d (expected %d)  429=%d (expected %d)  500=%d (expected %d) -> %s\n",
    http["202"], e202, http["429"], e429, http["500"], e500, httpOk ? "PASS" : "FAIL"

  dbOk = 1; line = ""
  for (i = 1; i <= 5; i++) {
    b = names[i]; want = saves[b] ? count[b] : 0; got = db[b] + 0
    line = line sprintf("%s=%d ", b, got); if (got != want) dbOk = 0
  }
  printf "Cross-check DB   : %s-> %s\n", line, dbOk ? "PASS" : "FAIL"

  exit !(ok && httpOk && dbOk)
}' "$WORK/decisions.txt"
result=$?

# Replay: run the simulator's own selector without HTTP and compare the full sequence line by line.
if command -v dotnet >/dev/null 2>&1; then
  seed="$(echo "$settings" | grep -oE 'seed=-?[0-9]+' | cut -d= -f2)"
  if dotnet run scripts/erp-simulator-replay.cs -- "$COUNT" "$seed" \
       "$(rate success)" "$(rate busy)" "$(rate serverError)" "$(rate saveThenError)" "$(rate lateResponse)" 2>/dev/null \
       | tr -d '\r' | grep -E '^[0-9]+ [A-Za-z]+$' > "$WORK/replay.txt" \
     && cmp -s "$WORK/replay.txt" "$WORK/decisions.txt"; then
    echo "Cross-check seed : logged sequence == offline replay of seed $seed ($COUNT decisions) -> PASS"
  else
    first="$(diff <(cat "$WORK/replay.txt") "$WORK/decisions.txt" | head -3 | tr '\n' ' ')"
    echo "Cross-check seed : logged sequence differs from offline replay of seed $seed: $first-> FAIL"
    result=1
  fi
else
  echo "Cross-check seed : skipped (dotnet SDK not installed)"
fi

# Back to the settings in appsettings.json.
docker compose up -d --force-recreate erp-simulator >/dev/null 2>&1
wait_healthy
exit $result
