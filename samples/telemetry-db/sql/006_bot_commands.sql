-- telemetry_006: Telegram bot commands (/status)
-- Allow-list of chats, request log, reply builder. The polling service
-- (telemetry-bot.sh) passes the raw getUpdates JSON to bot_process() and

BEGIN;
SET ROLE telemetry_app;
SET search_path = telemetry;

-- who may use the bot (owner adds people by chat ID)
CREATE TABLE bot_users (
    chat_id   bigint PRIMARY KEY,
    name      text NOT NULL,
    active    boolean NOT NULL DEFAULT true,
    added_at  timestamptz NOT NULL DEFAULT now()
);

-- every received update; max(update_id) is the polling offset
CREATE TABLE bot_requests (
    update_id    bigint PRIMARY KEY,
    received_at  timestamptz NOT NULL DEFAULT now(),
    chat_id      bigint,
    username     text,
    message      text,
    allowed      boolean NOT NULL
);

CREATE FUNCTION bot_offset() RETURNS bigint
LANGUAGE sql STABLE SET search_path = telemetry, public AS $$
    SELECT COALESCE(max(update_id), 0) + 1 FROM bot_requests
$$;

-- current temperatures, alarm state and node link
CREATE FUNCTION status_text() RETURNS text
LANGUAGE plpgsql STABLE SET search_path = telemetry, public AS $$
DECLARE
    r        record;
    txt      text;
    age_min  integer;
    n_alarm  integer;
BEGIN
    txt := '🌡 Сейчас ' || fmt_local(now());

    FOR r IN
        SELECT c.name, c.kind, c.alarm_enabled, c.alarm_min_c, c.alarm_max_c,
               s.state, s.pending_since, s.alarm_since,
               m.value_c + c.calibration_offset_c AS val, m.received_at
          FROM channels c
          LEFT JOIN alarm_state s ON s.channel_id = c.channel_id
          LEFT JOIN LATERAL (
                SELECT x.value_c, x.received_at
                  FROM measurements x
                 WHERE x.node_id = c.node_id AND x.sensor_id = c.sensor_id
                   AND x.quality IN ('ok', 'suspect') AND x.value_c IS NOT NULL
                 ORDER BY x.received_at DESC
                 LIMIT 1) m ON true
         WHERE c.active AND c.sensor_id IS NOT NULL
         ORDER BY c.kind, c.channel_id
    LOOP
        txt := txt || E'\n\n' || CASE WHEN r.kind = 'freezer' THEN '❄️ ' ELSE '🏭 ' END || r.name || ': ';
        IF r.received_at IS NULL THEN
            txt := txt || 'нет данных';
            CONTINUE;
        END IF;
        age_min := (extract(epoch FROM now() - r.received_at) / 60)::int;
        txt := txt || trim_scale(r.val) || ' °C · '
                   || CASE WHEN age_min > 15 THEN '⚠️ ' ELSE '' END
                   || fmt_duration(age_min) || ' назад'
                   || E'\n   '
                   || CASE WHEN NOT r.alarm_enabled THEN 'тревога выключена'
                           WHEN r.state = 'ALARM'   THEN '🚨 ТРЕВОГА с ' || fmt_local(r.alarm_since)
                           WHEN r.state = 'PENDING' THEN '⏳ вне нормы с ' || fmt_local(r.pending_since)
                           ELSE '✅ норма' END
                   || ' (' || COALESCE(trim_scale(r.alarm_min_c)::text, '') || '…'
                   || COALESCE(trim_scale(r.alarm_max_c)::text, '') || ')';
    END LOOP;

    txt := txt || E'\n';
    FOR r IN
        SELECT n.node_id, COALESCE(s.offline, false) AS offline
          FROM nodes n
          LEFT JOIN node_state s ON s.node_id = n.node_id
         WHERE EXISTS (SELECT 1 FROM channels c WHERE c.node_id = n.node_id AND c.active)
         ORDER BY n.node_id
    LOOP
        txt := txt || E'\n📡 Плата ' || r.node_id || ': '
                   || CASE WHEN r.offline THEN '⚠️ не на связи' ELSE 'на связи' END;
    END LOOP;

    SELECT count(*) INTO n_alarm
      FROM alarm_state a JOIN channels c ON c.channel_id = a.channel_id
     WHERE a.state = 'ALARM' AND c.alarm_enabled;
    txt := txt || E'\n🔔 Открытых тревог: ' || n_alarm;
    RETURN txt;
END;
$$;

-- takes the raw getUpdates JSON, logs new updates, returns replies to send
CREATE FUNCTION bot_process(p jsonb) RETURNS TABLE (to_chat bigint, reply text)
LANGUAGE plpgsql SET search_path = telemetry, public AS $$
DECLARE
    u       jsonb;
    v_chat  bigint;
    v_text  text;
    v_cmd   text;
    v_ok    boolean;
BEGIN
    FOR u IN SELECT * FROM jsonb_array_elements(COALESCE(p -> 'result', '[]'::jsonb)) LOOP
        v_chat := (u #>> '{message,chat,id}')::bigint;
        v_text := u #>> '{message,text}';
        v_ok   := EXISTS (SELECT 1 FROM bot_users b WHERE b.chat_id = v_chat AND b.active);

        INSERT INTO bot_requests (update_id, chat_id, username, message, allowed)
        VALUES ((u ->> 'update_id')::bigint, v_chat,
                COALESCE(u #>> '{message,from,username}', u #>> '{message,from,first_name}'),
                left(v_text, 500), v_ok)
        ON CONFLICT (update_id) DO NOTHING;
        CONTINUE WHEN NOT FOUND;                                   -- already handled
        CONTINUE WHEN v_chat IS NULL;                              -- not a message
        CONTINUE WHEN (u #>> '{message,date}')::bigint
                      < extract(epoch FROM now()) - 600;           -- older than 10 min

        to_chat := v_chat;
        IF NOT v_ok THEN
            reply := '⛔ Нет доступа. Ваш ID: ' || v_chat || E'\nПередайте его владельцу бота.';
            RETURN NEXT;
            CONTINUE;
        END IF;

        v_cmd := lower(regexp_replace(trim(COALESCE(v_text, '')), '@\S+$', ''));
        reply := CASE WHEN v_cmd IN ('/status', 'status', 't', 'т', 'статус') THEN status_text()
                      ELSE E'🤖 Команды:\n/status — температуры сейчас' END;
        RETURN NEXT;
    END LOOP;
END;
$$;

RESET ROLE;
COMMIT;
