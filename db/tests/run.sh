#!/usr/bin/env bash
# Terapkan migration (urutan sama dengan Flyway) ke database lokal lalu jalankan
# test SQL (RLS & aturan otorisasi) sebagai role pos_api, persis seperti backend.
#
# Pemakaian:
#   PGHOST=localhost PGUSER=postgres ./db/tests/run.sh            # buat DB baru & test
#   POS_TEST_DB=pos_rls_test ./db/tests/run.sh
#
# Hanya untuk lokal/CI: script ini DROP database target.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DB="${POS_TEST_DB:-pos_rls_test}"
API_PASSWORD="${POS_API_TEST_PASSWORD:-pos_api_test_only}"
PSQL_ADMIN=(psql -X -q -v ON_ERROR_STOP=1 -d "$DB")

case "$DB" in
  *prod*|*staging*) echo "Menolak menjalankan test pada database '$DB'" >&2; exit 2 ;;
esac

echo "==> recreate database $DB"
dropdb --if-exists "$DB"
createdb "$DB"

apply() {
  local f="$1"
  echo "    apply $(basename "$f")"
  "${PSQL_ADMIN[@]}" -1 -f "$f" >/dev/null
}

echo "==> migrations"
for f in "$ROOT"/db/local/V*.sql; do apply "$f"; done
for f in $(ls "$ROOT"/db/migration/V*.sql | sort -V); do apply "$f"; done
for f in "$ROOT"/db/seed/R__*.sql; do apply "$f"; done

echo "==> test helpers"
"${PSQL_ADMIN[@]}" -c "ALTER ROLE pos_api LOGIN PASSWORD '${API_PASSWORD}'" >/dev/null
"${PSQL_ADMIN[@]}" -1 -f "$ROOT/db/tests/_helpers.sql" >/dev/null

echo "==> tests"
pass=0; fail=0
for t in "$ROOT"/db/tests/test_*.sql; do
  name="$(basename "$t")"
  if out=$(PGPASSWORD="$API_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 -h "${PGHOST:-localhost}" \
            -U pos_api -d "$DB" -f "$t" 2>&1); then
    n=$(grep -c 'ok - ' <<<"$out" || true)
    echo "  PASS $name ($n assertions)"
    pass=$((pass+1))
  else
    echo "  FAIL $name"
    grep -E 'ok - |ERROR|FAIL' <<<"$out" | sed 's/^/      /' | tail -n 15
    fail=$((fail+1))
  fi
done

echo "==> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
