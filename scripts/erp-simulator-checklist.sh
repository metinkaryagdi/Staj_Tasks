#!/usr/bin/env bash
# Runs the Day 1 ERP Simulator checklist against the docker compose stack.
# Each scenario recreates the simulator container with its own rate overrides, so the
# seeded RNG starts from scratch. Invoice numbers carry a per-run prefix, so the DB
# never needs to be wiped between runs.
#
# Usage: ./scripts/erp-simulator-checklist.sh        (from the repo root, stack built once)

set -uo pipefail
cd "$(dirname "$0")/.."

BASE_URL="http://localhost:5080"
RUN_ID="$(date +%Y%m%d%H%M%S)"
PASS=0
FAIL=0
RESULTS=()

log()    { printf '\n=== %s ===\n' "$*"; }
record() {
  local status="$1" name="$2" detail="$3"
  if [[ "$status" == PASS ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
  RESULTS+=("[$status] $name - $detail")
  printf '[%s] %s - %s\n' "$status" "$name" "$detail"
}

# restart_simulator VAR=VALUE ...   -> recreate the container with the given overrides
restart_simulator() {
  env "$@" docker compose up -d --force-recreate erp-simulator >/dev/null 2>&1
  for _ in $(seq 1 60); do
    curl -sf "$BASE_URL/health" >/dev/null && return 0
    sleep 1
  done
  echo "Simulator did not become healthy" >&2
  exit 1
}

zero_rates=(Simulator__Rates__Busy=0 Simulator__Rates__ServerError=0 Simulator__Rates__SaveThenError=0 Simulator__Rates__LateResponse=0)

invoice_json() {
  printf '{"invoiceNumber":"%s","customerCode":"C-001","amount":1250.50,"currency":"TRY","invoiceDate":"2026-09-29"}' "$1"
}

# post_invoice NUMBER -> prints "<status>|<retry-after header>|<seconds>"
post_invoice() {
  local headers status retry_after elapsed
  headers="$(mktemp)"
  read -r status elapsed < <(curl -s -o /dev/null -D "$headers" --max-time 90 \
    -w '%{http_code} %{time_total}\n' \
    -H 'Content-Type: application/json' -d "$(invoice_json "$1")" \
    "$BASE_URL/api/v1/invoices")
  retry_after="$(grep -i '^retry-after:' "$headers" | cut -d' ' -f2- | tr -d '\r')"
  rm -f "$headers"
  echo "$status|$retry_after|$elapsed"
}

db_count() {
  docker compose exec -T erp-db psql -U erp -d erp_simulator -tAc \
    "SELECT count(*) FROM invoices WHERE invoice_number LIKE '$1%';" | tr -d '[:space:]'
}

behavior_sequence() {
  docker compose logs erp-simulator --no-log-prefix 2>/dev/null \
    | grep "invoice=$1" | grep -o 'behavior=[A-Za-z]*' | cut -d= -f2
}

docker compose up -d --build >/dev/null 2>&1 || { echo "docker compose up failed" >&2; exit 1; }

# ---------------------------------------------------------------------------
log "1) All failure rates 0 -> 100 invoices, 100 x 202, 100 rows"
restart_simulator "${zero_rates[@]}"
prefix="T1-$RUN_ID-"
ok=0
for i in $(seq 1 100); do
  [[ "$(post_invoice "$prefix$i" | cut -d'|' -f1)" == 202 ]] && ok=$((ok + 1))
done
rows="$(db_count "$prefix")"
[[ $ok -eq 100 && $rows -eq 100 ]] && s=PASS || s=FAIL
record $s "1 zero-failure" "202 responses=$ok/100, db rows=$rows"

# ---------------------------------------------------------------------------
log "2) Busy 100% -> every request 429 + Retry-After (5..30), no rows"
restart_simulator Simulator__Rates__Busy=100 Simulator__Rates__ServerError=0 Simulator__Rates__SaveThenError=0 Simulator__Rates__LateResponse=0
prefix="T2-$RUN_ID-"
ok=0; bad_header=0; values=()
for i in $(seq 1 20); do
  IFS='|' read -r status retry _ < <(post_invoice "$prefix$i")
  [[ "$status" == 429 ]] && ok=$((ok + 1))
  if [[ "$retry" =~ ^[0-9]+$ && $retry -ge 5 && $retry -le 30 ]]; then values+=("$retry"); else bad_header=$((bad_header + 1)); fi
done
rows="$(db_count "$prefix")"
[[ $ok -eq 20 && $bad_header -eq 0 && $rows -eq 0 ]] && s=PASS || s=FAIL
record $s "2 busy" "429 responses=$ok/20, invalid Retry-After=$bad_header, values=[${values[*]}], db rows=$rows"

# ---------------------------------------------------------------------------
log "3) SaveThenError 100% -> every request 500, every invoice in DB"
restart_simulator Simulator__Rates__Busy=0 Simulator__Rates__ServerError=0 Simulator__Rates__SaveThenError=100 Simulator__Rates__LateResponse=0
prefix="T3-$RUN_ID-"
ok=0
for i in $(seq 1 20); do
  [[ "$(post_invoice "$prefix$i" | cut -d'|' -f1)" == 500 ]] && ok=$((ok + 1))
done
rows="$(db_count "$prefix")"
[[ $ok -eq 20 && $rows -eq 20 ]] && s=PASS || s=FAIL
record $s "3 save-then-error" "500 responses=$ok/20, db rows=$rows"

# ---------------------------------------------------------------------------
log "4) LateResponse 100% -> 202 after ~30s, invoice in DB"
restart_simulator Simulator__Rates__Busy=0 Simulator__Rates__ServerError=0 Simulator__Rates__SaveThenError=0 Simulator__Rates__LateResponse=100
prefix="T4-$RUN_ID-"
ok=0; times=()
for i in 1 2; do
  IFS='|' read -r status _ elapsed < <(post_invoice "$prefix$i")
  times+=("${elapsed}s")
  if [[ "$status" == 202 ]] && awk -v t="$elapsed" 'BEGIN { exit !(t >= 30 && t < 35) }'; then ok=$((ok + 1)); fi
done
rows="$(db_count "$prefix")"
[[ $ok -eq 2 && $rows -eq 2 ]] && s=PASS || s=FAIL
record $s "4 late-response" "202 within 30-35s=$ok/2, durations=[${times[*]}], db rows=$rows"

# ---------------------------------------------------------------------------
log "5) Same invoice number twice -> two rows, different ERP references"
restart_simulator "${zero_rates[@]}"
number="T5-$RUN_ID-DUP"
s1="$(post_invoice "$number" | cut -d'|' -f1)"
s2="$(post_invoice "$number" | cut -d'|' -f1)"
refs="$(docker compose exec -T erp-db psql -U erp -d erp_simulator -tAc \
  "SELECT string_agg(erp_reference, ',' ORDER BY id), count(DISTINCT erp_reference) FROM invoices WHERE invoice_number = '$number';")"
distinct="${refs##*|}"
[[ "$s1" == 202 && "$s2" == 202 && "$distinct" == 2 ]] && s=PASS || s=FAIL
record $s "5 duplicates" "statuses=$s1,$s2, references=${refs%%|*}"

# ---------------------------------------------------------------------------
log "6) Default rates, same seed, 50 invoices x 2 runs -> identical behavior sequence (includes ~30s late responses)"
seqs=()
for run in A B; do
  restart_simulator
  prefix="T6-$RUN_ID-"
  for i in $(seq 1 50); do post_invoice "$prefix$i" >/dev/null; done
  seqs+=("$(behavior_sequence "$prefix" | tr '\n' ' ')")
done
summary="$(echo "${seqs[0]}" | tr ' ' '\n' | grep -v '^$' | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}')"
count_a="$(echo "${seqs[0]}" | wc -w)"
[[ -n "${seqs[0]// /}" && "${seqs[0]}" == "${seqs[1]}" && $count_a -eq 50 ]] && s=PASS || s=FAIL
record $s "6 seed determinism" "run A == run B ($count_a behaviors), distribution: $summary"
echo "Run A: ${seqs[0]}"
echo "Run B: ${seqs[1]}"

# ---------------------------------------------------------------------------
log "7) GET existing -> 200 with ERP reference, GET missing -> 404"
existing="T1-$RUN_ID-1"
body="$(curl -s "$BASE_URL/api/v1/invoices/$existing")"
get_status="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/api/v1/invoices/$existing")"
ref="$(echo "$body" | grep -o '"erpReference":"[^"]*"' | head -1 | cut -d'"' -f4)"
missing_status="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/api/v1/invoices/DOES-NOT-EXIST-$RUN_ID")"
[[ "$get_status" == 200 && "$ref" == ERP-* && "$missing_status" == 404 ]] && s=PASS || s=FAIL
record $s "7 lookup" "existing=$get_status ($ref), missing=$missing_status"

# Leave the simulator running with the settings from appsettings.json.
restart_simulator

printf '\n=== SUMMARY (run %s) ===\n' "$RUN_ID"
printf '%s\n' "${RESULTS[@]}"
printf 'Passed: %d  Failed: %d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
