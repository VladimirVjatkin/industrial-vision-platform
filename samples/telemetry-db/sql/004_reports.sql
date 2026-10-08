-- Day = local calendar day Europe/Prague. Durations are counted from 5-minute samples.

BEGIN;
SET ROLE telemetry_app;
SET search_path = telemetry;

CREATE FUNCTION fmt_duration(p_min integer) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_min >= 60 THEN (p_min / 60) || ' ч ' || (p_min % 60) || ' мин'
                ELSE p_min || ' мин' END
$$;

-- Short text summary of one day (Telegram and the summary file)
CREATE FUNCTION daily_summary(p_day date) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
    t0       timestamptz := p_day::timestamp AT TIME ZONE 'Europe/Prague';
    t1       timestamptz := (p_day + 1)::timestamp AT TIME ZONE 'Europe/Prague';
    expected numeric;
    r        record;
    txt      text;
    ev       text;
BEGIN
    expected := extract(epoch FROM t1 - t0) / 300;     -- 288 samples (276 / 300 on DST days)
    txt := '📊 Сводка за ' || to_char(p_day, 'DD.MM.YYYY');

    FOR r IN
        SELECT c.channel_id, c.name, c.kind, c.alarm_min_c, c.alarm_max_c, c.alarm_enabled,
               round(avg(m.value_cal_c), 1)                              AS a,
               min(m.value_cal_c)                                        AS mn,
               max(m.value_cal_c)                                        AS mx,
               count(m.value_cal_c)                                      AS n,
               count(*) FILTER (WHERE m.value_cal_c > c.alarm_max_c)     AS n_hi,
               count(*) FILTER (WHERE m.value_cal_c < c.alarm_min_c)     AS n_lo
          FROM channels c
          LEFT JOIN v_measurements m
                 ON m.channel_id = c.channel_id
                AND m.event_time >= t0 AND m.event_time < t1
                AND m.quality IN ('ok', 'suspect')
         WHERE c.active AND c.sensor_id IS NOT NULL
         GROUP BY c.channel_id, c.name, c.kind, c.alarm_min_c, c.alarm_max_c, c.alarm_enabled
         ORDER BY c.kind, c.channel_id
    LOOP
        txt := txt || E'\n\n' || CASE WHEN r.kind = 'freezer' THEN '❄️ ' ELSE '🏭 ' END || r.name;
        IF r.n = 0 THEN
            txt := txt || E'\n   нет данных за сутки';
            CONTINUE;
        END IF;
        txt := txt || ': ср ' || trim_scale(r.a) || ' °C (мин ' || trim_scale(r.mn)
                   || ', макс ' || trim_scale(r.mx) || ')' || E'\n   ';
        IF r.alarm_max_c IS NOT NULL THEN
            txt := txt || 'выше ' || trim_scale(r.alarm_max_c) || ': ' || fmt_duration((r.n_hi * 5)::int) || ' · ';
        END IF;
        IF r.alarm_min_c IS NOT NULL THEN
            txt := txt || 'ниже ' || trim_scale(r.alarm_min_c) || ': ' || fmt_duration((r.n_lo * 5)::int) || ' · ';
        END IF;
        txt := txt || 'данные ' || least(100, round(r.n * 100 / expected))::int || ' %';
        IF NOT r.alarm_enabled THEN
            txt := txt || ' · тревога выключена';
        END IF;
    END LOOP;

    SELECT string_agg(x, E'\n   ' ORDER BY x) INTO ev FROM (
        SELECT COALESCE(c.name, 'узел ' || e.node_id) || ' — '
               || CASE e.event WHEN 'ALARM' THEN 'тревога'
                               WHEN 'STALE' THEN 'нет данных'
                               WHEN 'NODE_OFFLINE' THEN 'не на связи' END
               || ' ×' || count(*) AS x
          FROM alarm_events e
          LEFT JOIN channels c ON c.channel_id = e.channel_id
         WHERE e.created_at >= t0 AND e.created_at < t1
           AND e.event IN ('ALARM', 'STALE', 'NODE_OFFLINE')
         GROUP BY c.name, e.node_id, e.event) s;
    txt := txt || E'\n\n⚠️ Тревоги и сбои: ' || COALESCE(E'\n   ' || ev, 'нет');
    RETURN txt;
END;
$$;

-- CSV of 30-minute minima for one day: time,<channel 1>,<channel 2>,...
CREATE FUNCTION daily_csv(p_day date) RETURNS text
LANGUAGE sql STABLE AS $$
    WITH b AS (
        SELECT p_day::timestamp AT TIME ZONE 'Europe/Prague'       AS t0,
               (p_day + 1)::timestamp AT TIME ZONE 'Europe/Prague' AS t1),
    ch AS (
        SELECT channel_id, name FROM channels WHERE active AND sensor_id IS NOT NULL),
    slots AS (
        SELECT generate_series(b.t0, b.t1 - interval '30 minutes', interval '30 minutes') AS s FROM b),
    agg AS (
        SELECT v.channel_id, v.slot_start, v.min_c
          FROM v_channel_30min v, b
         WHERE v.slot_start >= b.t0 AND v.slot_start < b.t1),
    lines AS (
        SELECT sl.s,
               string_agg(COALESCE(trim_scale(a.min_c)::text, ''), ',' ORDER BY ch.channel_id) AS vals
          FROM slots sl
         CROSS JOIN ch
          LEFT JOIN agg a ON a.channel_id = ch.channel_id AND a.slot_start = sl.s
         GROUP BY sl.s)
    SELECT 'time,' || (SELECT string_agg('"' || name || '"', ',' ORDER BY channel_id) FROM ch)
           || E'\n'
           || string_agg(to_char(l.s AT TIME ZONE 'Europe/Prague', 'YYYY-MM-DD HH24:MI') || ',' || l.vals,
                         E'\n' ORDER BY l.s)
           || E'\n'
      FROM lines l
$$;

-- One row for workflow: default = yesterday (local)
CREATE FUNCTION daily_report(p_day date DEFAULT ((now() AT TIME ZONE 'Europe/Prague')::date - 1))
RETURNS TABLE (day text, year text, month text, summary text, csv text)
LANGUAGE sql STABLE AS $$
    SELECT to_char(p_day, 'YYYY-MM-DD'), to_char(p_day, 'YYYY'), to_char(p_day, 'MM'),
           daily_summary(p_day), daily_csv(p_day)
$$;

RESET ROLE;
COMMIT;
