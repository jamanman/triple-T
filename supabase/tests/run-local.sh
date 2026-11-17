#!/usr/bin/env bash
# Run the rules tests against a THROWAWAY plain Postgres 15+ database (not your
# Supabase project): it drops and recreates the game schema.
#   PGHOST=... PGPORT=... PGUSER=postgres PGDATABASE=scratch supabase/tests/run-local.sh
set -euo pipefail
cd "$(dirname "$0")"
psql -q -c "select 1 from pg_roles where rolname = 'authenticated'" | grep -q 1 || psql -q -v ON_ERROR_STOP=1 -f supabase_stub.sql
psql -q -f reset.sql >/dev/null 2>&1
for f in ../migrations/20261116000000_game_schema.sql ../migrations/20261116000200_*.sql ../migrations/20261116000300_*.sql ../migrations/20261117000000_*.sql ../migrations/20261117000100_*.sql ../migrations/20261117000200_*.sql ../migrations/20261117000300_*.sql; do psql -q -v ON_ERROR_STOP=1 -f "$f"; done
psql -f game_test.sql 2>&1 | grep -E 'ok -|FAIL|ERROR|PASSED'
