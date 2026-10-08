#!/usr/bin/env bash
set -euo pipefail
psql -d postgres -v ON_ERROR_STOP=1 -q <<'SQL'
DROP DATABASE IF EXISTS telemetry_restore WITH (FORCE);
DROP DATABASE IF EXISTS telemetry WITH (FORCE);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'telemetry_app') THEN
    CREATE ROLE telemetry_app LOGIN;
  END IF;
END $$;
CREATE DATABASE telemetry;
SQL
for migration in /sample/sql/00[1-7]_*.sql; do
  echo "Applying ${migration##*/}"
  psql -d telemetry -v ON_ERROR_STOP=1 -q -f "$migration"
done
psql -d telemetry -v ON_ERROR_STOP=1 -q -f /sample/tests/assertions.sql
pg_dump -Fc -d telemetry -f /tmp/telemetry.dump
createdb telemetry_restore
pg_restore --no-owner -d telemetry_restore /tmp/telemetry.dump
psql -d telemetry_restore -v ON_ERROR_STOP=1 -q -f /sample/tests/restore.sql
echo 'PASS: ingest, alarms, outbox, reports, bot and dump/restore'
