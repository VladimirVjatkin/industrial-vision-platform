-- telemetry_001: base schema for environmental telemetry

BEGIN;

ALTER DATABASE telemetry OWNER TO telemetry_app;
CREATE SCHEMA IF NOT EXISTS telemetry AUTHORIZATION telemetry_app;
ALTER ROLE telemetry_app IN DATABASE telemetry SET search_path = telemetry, public;

-- everything below is owned by telemetry_app
SET ROLE telemetry_app;
SET search_path = telemetry;

-- ---------------------------------------------------------------- tables

CREATE TABLE nodes (
    node_id          text PRIMARY KEY CHECK (node_id ~ '^[a-z0-9-]{3,32}$'),
    description      text,
    availability     text CHECK (availability IN ('online', 'offline')),
    availability_at  timestamptz,
    last_status      jsonb,
    last_status_at   timestamptz
);

CREATE TABLE channels (
    channel_id           text PRIMARY KEY,
    name                 text NOT NULL,
    kind                 text NOT NULL CHECK (kind IN ('freezer', 'outdoor', 'other')),
    node_id              text NOT NULL,
    sensor_id            text CHECK (sensor_id ~ '^[0-9A-F]{16}$'),  -- NULL until the probe ROM is known
    alarm_enabled        boolean NOT NULL DEFAULT false,
    alarm_threshold_c    numeric(5,2) NOT NULL DEFAULT -11,
    calibration_offset_c numeric(5,2) NOT NULL DEFAULT 0,
    active               boolean NOT NULL DEFAULT true,
    UNIQUE (node_id, sensor_id)
);

CREATE TABLE measurements (
    id               bigserial PRIMARY KEY,
    node_id          text        NOT NULL,
    sensor_id        text        NOT NULL,
    boot_id          uuid        NOT NULL,
    seq              bigint      NOT NULL CHECK (seq >= 0),
    value_c          numeric(6,2),
    unit             text        NOT NULL,
    quality          text        NOT NULL,
    measured_at      timestamptz,
    time_quality     text        NOT NULL,
    uptime_ms        bigint      NOT NULL,
    buffered         boolean     NOT NULL,
    firmware_version text,
    received_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (node_id, sensor_id, boot_id, seq)
);
CREATE INDEX measurements_sensor_received_idx ON measurements (node_id, sensor_id, received_at);

CREATE TABLE ingest_errors (
    id          bigserial PRIMARY KEY,
    received_at timestamptz NOT NULL DEFAULT now(),
    topic       text,
    payload     text,
    reason      text NOT NULL
);

-- ---------------------------------------------------------------- views

-- event_time (MQTT contract, "Time and idempotency"): live -> received_at; buffered -> measured_at only if synced
CREATE VIEW v_measurements AS
SELECT m.*,
       c.channel_id,
       c.name AS channel_name,
       CASE WHEN NOT m.buffered THEN m.received_at
            WHEN m.time_quality = 'synced' THEN m.measured_at
       END AS event_time,
       m.value_c + COALESCE(c.calibration_offset_c, 0) AS value_cal_c
FROM measurements m
LEFT JOIN channels c ON c.node_id = m.node_id AND c.sensor_id = m.sensor_id;

CREATE VIEW v_channel_30min AS
SELECT channel_id,
       channel_name,
       date_bin('30 minutes', event_time, TIMESTAMPTZ '2000-01-01 00:00:00+00') AS slot_start,
       min(value_cal_c) FILTER (WHERE quality IN ('ok', 'suspect')) AS min_c,
       count(*) FILTER (WHERE quality IN ('ok', 'suspect'))         AS valid_count,
       count(*)                                                     AS total_count
FROM v_measurements
WHERE event_time IS NOT NULL AND channel_id IS NOT NULL
GROUP BY 1, 2, 3;

-- ---------------------------------------------------------------- ingest: measurement

-- Returns {"ack_topic": ..., "ack_payload": {...}, "result": ..., "reason": ...}
-- ack_topic is NULL when the message cannot be acknowledged (unparseable key).
CREATE FUNCTION ingest_measurement(p_topic text, p_payload text)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    j        jsonb;
    t        text[];
    v_node   text;
    v_sensor text;
    v_boot   uuid;
    v_seq    bigint;
    v_value  numeric;
    v_meas   timestamptz;
    reason   text;
    result   text;
    ex       measurements%ROWTYPE;
    ty       text;
BEGIN
    -- JSON
    BEGIN
        j := p_payload::jsonb;
    EXCEPTION WHEN others THEN
        reason := 'invalid json';
    END;

    -- topic: ivp/telemetry/v1/nodes/<node>/sensors/<sensor>/measurement
    t := string_to_array(p_topic, '/');
    IF reason IS NULL AND (COALESCE(array_length(t, 1), 0) <> 8
        OR t[1] <> 'ivp' OR t[2] <> 'telemetry' OR t[3] <> 'v1'
        OR t[4] <> 'nodes' OR t[6] <> 'sensors' OR t[8] <> 'measurement') THEN
        reason := 'bad topic';
    END IF;
    IF reason IS NULL THEN
        v_node := t[5];
        v_sensor := t[7];
    END IF;

    -- key fields (needed to ack)
    IF reason IS NULL THEN
        BEGIN
            v_boot := (j->>'boot_id')::uuid;
            IF COALESCE(jsonb_typeof(j->'seq'), 'missing') <> 'number' THEN
                RAISE EXCEPTION 'seq';
            END IF;
            v_seq := (j->>'seq')::bigint;
            IF v_boot IS NULL OR v_seq < 0 THEN
                RAISE EXCEPTION 'key';
            END IF;
        EXCEPTION WHEN others THEN
            reason := 'boot_id/seq';
            v_boot := NULL;
            v_seq := NULL;
        END;
    END IF;

    -- content validation (MQTT contract, measurement field rules)
    IF reason IS NULL THEN
        ty := COALESCE(jsonb_typeof(j->'value'), 'missing');
        IF (j->>'schema_version') IS DISTINCT FROM '1' THEN reason := 'schema_version';
        ELSIF j->>'node_id' IS DISTINCT FROM v_node OR j->>'sensor_id' IS DISTINCT FROM v_sensor THEN reason := 'topic/payload id mismatch';
        ELSIF v_node !~ '^[a-z0-9-]{3,32}$' THEN reason := 'node_id format';
        ELSIF v_sensor !~ '^[0-9A-F]{16}$' THEN reason := 'sensor_id format';
        ELSIF (j->>'unit') IS DISTINCT FROM 'C' THEN reason := 'unit';
        ELSIF COALESCE(j->>'quality', '') NOT IN ('ok', 'not_found', 'crc_error', 'conversion_timeout', 'suspect') THEN reason := 'quality';
        ELSIF COALESCE(j->>'time_quality', '') NOT IN ('synced', 'estimated', 'unsynced') THEN reason := 'time_quality';
        ELSIF ty NOT IN ('number', 'null') THEN reason := 'value type';
        ELSIF ty = 'number' AND j->>'quality' NOT IN ('ok', 'suspect') THEN reason := 'value with error quality';
        ELSIF ty = 'null' AND j->>'quality' = 'ok' THEN reason := 'ok without value';
        ELSIF ty = 'number' AND ((j->>'value')::numeric < -55 OR (j->>'value')::numeric > 125) THEN reason := 'value out of range';
        ELSIF COALESCE(jsonb_typeof(j->'buffered'), 'missing') <> 'boolean' THEN reason := 'buffered';
        ELSIF COALESCE(jsonb_typeof(j->'uptime_ms'), 'missing') <> 'number' THEN reason := 'uptime_ms';
        ELSIF COALESCE(jsonb_typeof(j->'measured_at'), 'missing') NOT IN ('string', 'null') THEN reason := 'measured_at';
        END IF;
    END IF;

    IF reason IS NULL THEN
        BEGIN
            v_value := round((j->>'value')::numeric, 2);
            v_meas := (j->>'measured_at')::timestamptz;

            INSERT INTO measurements (node_id, sensor_id, boot_id, seq, value_c, unit, quality,
                                      measured_at, time_quality, uptime_ms, buffered, firmware_version)
            VALUES (v_node, v_sensor, v_boot, v_seq, v_value, 'C', j->>'quality',
                    v_meas, j->>'time_quality', (j->>'uptime_ms')::bigint,
                    (j->>'buffered')::boolean, j->>'firmware_version')
            ON CONFLICT (node_id, sensor_id, boot_id, seq) DO NOTHING;

            IF FOUND THEN
                result := 'stored';
            ELSE
                SELECT * INTO ex FROM measurements
                 WHERE node_id = v_node AND sensor_id = v_sensor AND boot_id = v_boot AND seq = v_seq;
                -- idempotency: compare content only (not buffered / firmware_version)
                IF ex.value_c IS NOT DISTINCT FROM v_value
                   AND ex.quality = j->>'quality'
                   AND ex.measured_at IS NOT DISTINCT FROM v_meas
                   AND ex.time_quality = j->>'time_quality'
                   AND ex.uptime_ms = (j->>'uptime_ms')::bigint THEN
                    result := 'duplicate';
                ELSE
                    reason := 'same key, different content';
                END IF;
            END IF;
        EXCEPTION WHEN others THEN
            reason := 'insert: ' || SQLERRM;
        END;
    END IF;

    IF reason IS NOT NULL THEN
        result := 'rejected';
        INSERT INTO ingest_errors (topic, payload, reason)
        VALUES (p_topic, left(p_payload, 4000), reason);
    END IF;

    RETURN jsonb_build_object(
        'result', result,
        'reason', reason,
        'ack_topic', CASE WHEN v_node IS NOT NULL AND v_boot IS NOT NULL AND v_seq IS NOT NULL
                          THEN 'ivp/telemetry/v1/nodes/' || v_node || '/ack' END,
        'ack_payload', jsonb_build_object(
            'schema_version', 1,
            'sensor_id', v_sensor,
            'boot_id', v_boot,
            'seq', v_seq,
            'result', result)
    );
END;
$$;

-- ---------------------------------------------------------------- ingest: status / availability

CREATE FUNCTION ingest_node_message(p_topic text, p_payload text)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    t      text[];
    v_node text;
    j      jsonb;
BEGIN
    t := string_to_array(p_topic, '/');
    IF COALESCE(array_length(t, 1), 0) <> 6 OR t[1] <> 'ivp' OR t[2] <> 'telemetry'
       OR t[3] <> 'v1' OR t[4] <> 'nodes' OR t[6] NOT IN ('status', 'availability')
       OR t[5] !~ '^[a-z0-9-]{3,32}$' THEN
        INSERT INTO ingest_errors (topic, payload, reason) VALUES (p_topic, left(p_payload, 4000), 'bad node topic');
        RETURN 'rejected';
    END IF;
    v_node := t[5];
    INSERT INTO nodes (node_id) VALUES (v_node) ON CONFLICT DO NOTHING;

    IF t[6] = 'availability' THEN
        IF p_payload NOT IN ('online', 'offline') THEN
            INSERT INTO ingest_errors (topic, payload, reason) VALUES (p_topic, left(p_payload, 4000), 'bad availability');
            RETURN 'rejected';
        END IF;
        UPDATE nodes SET availability = p_payload, availability_at = now() WHERE node_id = v_node;
    ELSE
        BEGIN
            j := p_payload::jsonb;
        EXCEPTION WHEN others THEN
            INSERT INTO ingest_errors (topic, payload, reason) VALUES (p_topic, left(p_payload, 4000), 'invalid status json');
            RETURN 'rejected';
        END;
        UPDATE nodes SET last_status = j, last_status_at = now() WHERE node_id = v_node;
    END IF;
    RETURN 'stored';
END;
$$;


INSERT INTO nodes (node_id, description) VALUES ('sensor-node-a', 'Synthetic temperature node');

INSERT INTO channels (channel_id, name, kind, node_id, alarm_enabled) VALUES
    ('freezer-a', 'Freezer A', 'freezer', 'sensor-node-a', true),
    ('freezer-b', 'Freezer B', 'freezer', 'sensor-node-a', true),
    ('workshop',    'Room',        'other', 'sensor-node-a', false);
-- sensor_id (DS18B20 ROM) is assigned later:
-- UPDATE telemetry.channels SET sensor_id = '<ROM>' WHERE channel_id = 'freezer-a';

RESET ROLE;
COMMIT;
