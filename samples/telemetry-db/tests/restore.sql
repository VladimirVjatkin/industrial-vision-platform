SET search_path = public;
DO $$
DECLARE missing integer;
BEGIN
  SELECT count(*) INTO missing
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='telemetry' AND p.prokind IN ('f','p')
     AND NOT ('search_path=telemetry, public'=ANY(COALESCE(p.proconfig, ARRAY[]::text[])));
  IF missing<>0 THEN RAISE EXCEPTION '% routines lost pinned search_path',missing; END IF;
  IF position('Сводка' in telemetry.daily_summary((now() AT TIME ZONE 'Europe/Prague')::date))=0 THEN
    RAISE EXCEPTION 'restored function failed';
  END IF;
  IF telemetry.bot_offset()<1 THEN RAISE EXCEPTION 'restored bot function failed'; END IF;
END $$;
SELECT 'PASS: fresh pg_dump restore and pinned search_path' AS result;
