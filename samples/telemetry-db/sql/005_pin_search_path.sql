-- telemetry_005: pin search_path inside every telemetry function/procedure,
-- so a pg_dump/pg_restore works without the role-in-database setting
-- (ALTER ROLE ... IN DATABASE is not part of a database dump).
SET search_path = telemetry;

DO $$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS f
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'telemetry' AND p.prokind IN ('f', 'p')
    LOOP
        EXECUTE format('ALTER ROUTINE %s SET search_path = telemetry, public', r.f);
    END LOOP;
END $$;
