-- telemetry_003: alarm range per channel (min / max) instead of a single threshold

BEGIN;
SET ROLE telemetry_app;
SET search_path = telemetry;

ALTER TABLE channels ADD COLUMN alarm_min_c numeric(5,2);
ALTER TABLE channels ADD COLUMN alarm_max_c numeric(5,2);
UPDATE channels SET alarm_min_c = -25, alarm_max_c = -11 WHERE kind = 'freezer';
UPDATE channels SET alarm_min_c = 6, alarm_max_c = 35, alarm_enabled = true WHERE channel_id = 'workshop';
ALTER TABLE channels DROP COLUMN alarm_threshold_c;
ALTER TABLE channels ADD CONSTRAINT channels_alarm_range_chk
    CHECK (NOT alarm_enabled OR alarm_min_c IS NOT NULL OR alarm_max_c IS NOT NULL);
ALTER TABLE channels ADD CONSTRAINT channels_alarm_order_chk
    CHECK (alarm_min_c IS NULL OR alarm_max_c IS NULL OR alarm_min_c + 2 <= alarm_max_c);

CREATE OR REPLACE FUNCTION evaluate_alarms() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_now        timestamptz := now();
    n            record;
    ns           node_state%ROWTYPE;
    v_off        boolean;
    c            record;
    st           alarm_state%ROWTYPE;
    v_node_off   boolean;
    v_last_time  timestamptz;
    v_last_val   numeric;
    v_gap_break  timestamptz;
    v_bad_time   timestamptz;
    v_first_ok   timestamptz;
    v_max_gap    interval;
    v_min        numeric;
    v_max        numeric;
    v_rule       text;
    v_created    integer := 0;
BEGIN
    -- ------------------------------------------------ nodes: offline after 3 min, notify after 15 min
    FOR n IN SELECT * FROM nodes LOOP
        INSERT INTO node_state (node_id) VALUES (n.node_id) ON CONFLICT DO NOTHING;
        SELECT * INTO ns FROM node_state WHERE node_id = n.node_id FOR UPDATE;

        v_off := n.last_status_at IS NULL
                 OR v_now - n.last_status_at > interval '3 minutes'
                 OR n.availability = 'offline';
        IF v_off THEN
            ns.offline := true;
            IF NOT ns.offline_notified
               AND (n.last_status_at IS NULL OR v_now - n.last_status_at > interval '15 minutes') THEN
                PERFORM add_notification(NULL, n.node_id, 'NODE_OFFLINE', NULL,
                    '⚠️ Узел ' || n.node_id || ' не на связи' || E'\nПоследний сигнал: ' || fmt_local(n.last_status_at));
                ns.offline_notified := true;
                v_created := v_created + 1;
            END IF;
        ELSE
            IF ns.offline_notified THEN
                PERFORM add_notification(NULL, n.node_id, 'NODE_ONLINE', NULL,
                    '✅ Узел ' || n.node_id || ' снова на связи');
                v_created := v_created + 1;
            END IF;
            ns.offline := false;
            ns.offline_notified := false;
        END IF;
        UPDATE node_state SET offline = ns.offline, offline_notified = ns.offline_notified, updated_at = v_now
         WHERE node_id = n.node_id;
    END LOOP;

    -- ------------------------------------------------ channels
    FOR c IN SELECT * FROM channels WHERE active AND sensor_id IS NOT NULL LOOP
        INSERT INTO alarm_state (channel_id) VALUES (c.channel_id) ON CONFLICT DO NOTHING;
        SELECT * INTO st FROM alarm_state WHERE channel_id = c.channel_id FOR UPDATE;
        v_node_off := false;
        SELECT offline INTO v_node_off FROM node_state WHERE node_id = c.node_id;
        v_node_off := COALESCE(v_node_off, false);
        v_min := c.alarm_min_c;
        v_max := c.alarm_max_c;
        v_rule := CASE
            WHEN v_min IS NULL THEN 'выше ' || trim_scale(v_max) || ' °C'
            WHEN v_max IS NULL THEN 'ниже ' || trim_scale(v_min) || ' °C'
            ELSE 'вне ' || trim_scale(v_min) || '…' || trim_scale(v_max) || ' °C' END;

        v_last_time := NULL;
        v_last_val := NULL;
        SELECT event_time, value_cal_c INTO v_last_time, v_last_val
          FROM v_measurements
         WHERE channel_id = c.channel_id AND event_time IS NOT NULL
           AND quality IN ('ok', 'suspect') AND value_cal_c IS NOT NULL
         ORDER BY event_time DESC LIMIT 1;

        -- stale: no valid value for 6 min; notify after 15 min (not while the whole node is offline)
        IF v_last_time IS NULL OR v_now - v_last_time > interval '6 minutes' THEN
            st.stale := true;
            IF NOT st.stale_notified AND NOT v_node_off
               AND (v_last_time IS NULL OR v_now - v_last_time > interval '15 minutes') THEN
                PERFORM add_notification(c.channel_id, c.node_id, 'STALE', v_last_val,
                    '⚠️ Нет данных: ' || c.name || E'\nПоследний замер: ' || fmt_local(v_last_time)
                    || COALESCE(' (' || v_last_val || ' °C)', ''));
                st.stale_notified := true;
                v_created := v_created + 1;
            END IF;
        ELSE
            IF st.stale_notified THEN
                PERFORM add_notification(c.channel_id, c.node_id, 'DATA_RESTORED', v_last_val,
                    '✅ Данные снова поступают: ' || c.name || E'\nСейчас: ' || v_last_val || ' °C');
                v_created := v_created + 1;
            END IF;
            st.stale := false;
            st.stale_notified := false;
        END IF;

        IF NOT c.alarm_enabled THEN
            st.state := 'NORMAL';
            st.pending_since := NULL;
            st.alarm_since := NULL;
        ELSE
            -- NORMAL -> PENDING: latest live value above threshold
            IF st.state = 'NORMAL' AND NOT st.stale
               AND (v_last_val > v_max OR v_last_val < v_min) THEN
                st.state := 'PENDING';
                st.pending_since := v_last_time;
            END IF;

            IF st.state = 'PENDING' THEN
                IF EXISTS (SELECT 1 FROM v_measurements
                            WHERE channel_id = c.channel_id AND event_time >= st.pending_since
                              AND quality IN ('ok', 'suspect')
                              AND (v_max IS NULL OR value_cal_c <= v_max)
                              AND (v_min IS NULL OR value_cal_c >= v_min)) THEN
                    st.state := 'NORMAL';                       -- dropped back: reset
                    st.pending_since := NULL;
                ELSE
                    -- continuity: restart the window after any gap > 6 min
                    SELECT max(event_time) INTO v_gap_break FROM (
                        SELECT event_time, lag(event_time) OVER (ORDER BY event_time) AS prev
                          FROM v_measurements
                         WHERE channel_id = c.channel_id AND event_time >= st.pending_since
                           AND quality IN ('ok', 'suspect') AND value_cal_c IS NOT NULL) x
                     WHERE event_time - prev > interval '6 minutes';
                    IF v_gap_break IS NOT NULL THEN
                        st.pending_since := v_gap_break;
                    END IF;

                    IF v_last_time - st.pending_since >= interval '20 minutes'
                       AND v_now - v_last_time <= interval '6 minutes' THEN
                        st.state := 'ALARM';
                        st.alarm_since := st.pending_since;
                        st.last_notified_at := v_now;
                        PERFORM add_notification(c.channel_id, c.node_id, 'ALARM', v_last_val,
                            '🚨 ТРЕВОГА: ' || c.name
                            || E'\nТемпература: ' || v_last_val || ' °C (тревога: ' || v_rule || ')'
                            || E'\nВне нормы с: ' || fmt_local(st.pending_since)
                            || E'\nПоследний замер: ' || fmt_local(v_last_time));
                        v_created := v_created + 1;
                    END IF;
                END IF;

            ELSIF st.state = 'ALARM' THEN
                -- recovery: valid values <= threshold - 1 for 10 min without gaps > 6 min
                SELECT max(event_time) INTO v_bad_time FROM v_measurements
                 WHERE channel_id = c.channel_id AND event_time >= st.alarm_since
                   AND quality IN ('ok', 'suspect')
                   AND (value_cal_c > v_max - 1 OR value_cal_c < v_min + 1);
                SELECT min(event_time) INTO v_first_ok FROM v_measurements
                 WHERE channel_id = c.channel_id AND event_time > COALESCE(v_bad_time, st.alarm_since)
                   AND quality IN ('ok', 'suspect') AND value_cal_c IS NOT NULL;
                SELECT max(event_time - prev) INTO v_max_gap FROM (
                    SELECT event_time, lag(event_time) OVER (ORDER BY event_time) AS prev
                      FROM v_measurements
                     WHERE channel_id = c.channel_id AND event_time >= v_first_ok
                       AND quality IN ('ok', 'suspect') AND value_cal_c IS NOT NULL) x;

                IF v_first_ok IS NOT NULL
                   AND v_last_time - v_first_ok >= interval '10 minutes'
                   AND COALESCE(v_max_gap, interval '0') <= interval '6 minutes'
                   AND v_now - v_last_time <= interval '6 minutes' THEN
                    PERFORM add_notification(c.channel_id, c.node_id, 'RECOVERED', v_last_val,
                        '✅ Норма: ' || c.name
                        || E'\nТемпература: ' || v_last_val || ' °C'
                        || E'\nТревога длилась с ' || fmt_local(st.alarm_since) || ' по ' || fmt_local(v_last_time));
                    st.state := 'NORMAL';
                    st.pending_since := NULL;
                    st.alarm_since := NULL;
                    v_created := v_created + 1;
                ELSIF v_now - st.last_notified_at >= interval '60 minutes' THEN
                    PERFORM add_notification(c.channel_id, c.node_id, 'REMINDER', v_last_val,
                        '⏰ Тревога продолжается: ' || c.name
                        || E'\nПоследний замер: ' || COALESCE(v_last_val || ' °C в ' || fmt_local(v_last_time), 'нет данных')
                        || E'\nВ тревоге с: ' || fmt_local(st.alarm_since));
                    st.last_notified_at := v_now;
                    v_created := v_created + 1;
                END IF;
            END IF;
        END IF;

        UPDATE alarm_state
           SET state = st.state, pending_since = st.pending_since, alarm_since = st.alarm_since,
               last_notified_at = st.last_notified_at, stale = st.stale,
               stale_notified = st.stale_notified, updated_at = v_now
         WHERE channel_id = c.channel_id;
    END LOOP;

    RETURN v_created;
END;
$$;

RESET ROLE;
COMMIT;
