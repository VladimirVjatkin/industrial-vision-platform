SET search_path = telemetry, public;
DO $$
DECLARE
  topic text := 'ivp/telemetry/v1/nodes/sensor-node-a/sensors/28AA000000000001/measurement';
  payload jsonb := jsonb_build_object('schema_version',1,'node_id','sensor-node-a',
      'sensor_id','28AA000000000001','boot_id','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'seq',1,'measured_at',now(),'uptime_ms',300000,'value',-18.5,'unit','C',
      'quality','ok','time_quality','synced','buffered',false,'firmware_version','sample-1');
  result jsonb;
  count_before bigint;
BEGIN
  UPDATE nodes SET availability='online', last_status_at=now() WHERE node_id='sensor-node-a';
  result := ingest_measurement(topic, payload::text);
  IF result->>'result' <> 'stored' THEN RAISE EXCEPTION 'valid ingest: %', result; END IF;
  result := ingest_measurement(topic, payload::text);
  IF result->>'result' <> 'duplicate' THEN RAISE EXCEPTION 'idempotent duplicate: %', result; END IF;
  IF (SELECT count(*) FROM measurements) <> 1 THEN RAISE EXCEPTION 'duplicate inserted a row'; END IF;
  result := ingest_measurement(topic, (payload || '{"value":-17.5}'::jsonb)::text);
  IF result->>'result' <> 'rejected' THEN RAISE EXCEPTION 'conflicting duplicate'; END IF;
  result := ingest_measurement(topic, (payload || '{"quality":"not_found"}'::jsonb)::text);
  IF result->>'result' <> 'rejected' THEN RAISE EXCEPTION 'invalid value/quality'; END IF;
  result := ingest_measurement(topic, '{bad json');
  IF result->>'result' <> 'rejected' THEN RAISE EXCEPTION 'invalid JSON'; END IF;
  IF (SELECT count(*) FROM ingest_errors) <> 3 THEN RAISE EXCEPTION 'error logging'; END IF;
  IF (SELECT value_cal_c FROM v_measurements WHERE seq=1) <> -18.25 THEN RAISE EXCEPTION 'calibration'; END IF;
  UPDATE measurements SET received_at=now()-interval '30 minutes' WHERE seq=1;
  -- Backdated source rows preserve the unchanged production clock logic.
  INSERT INTO measurements(node_id,sensor_id,boot_id,seq,value_c,unit,quality,measured_at,time_quality,uptime_ms,buffered,received_at)
  SELECT 'sensor-node-a','28AA000000000001','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
         100+n,-9,'C','ok',now()-(20-n*5)*interval '1 minute','synced',n*300000,false,
         now()-(20-n*5)*interval '1 minute'
  FROM generate_series(0,4) n;
  PERFORM evaluate_alarms();
  IF (SELECT state FROM alarm_state WHERE channel_id='freezer-a') <> 'PENDING' THEN
    RAISE EXCEPTION 'PENDING not entered';
  END IF;
  UPDATE alarm_state SET pending_since=now()-interval '20 minutes' WHERE channel_id='freezer-a';
  PERFORM evaluate_alarms();
  IF (SELECT state FROM alarm_state WHERE channel_id='freezer-a') <> 'ALARM' THEN
    RAISE EXCEPTION 'ALARM not entered after hold';
  END IF;
  PERFORM evaluate_alarms();
  IF (SELECT count(*) FROM alarm_events WHERE event='ALARM' AND channel_id='freezer-a') <> 1 THEN
    RAISE EXCEPTION 'ALARM emitted more than once';
  END IF;
  -- Move the high-temperature series into history to test recovery at the current clock.
  UPDATE measurements SET received_at=received_at-interval '15 minutes' WHERE seq BETWEEN 100 AND 104;
  INSERT INTO measurements(node_id,sensor_id,boot_id,seq,value_c,unit,quality,measured_at,time_quality,uptime_ms,buffered,received_at)
  VALUES ('sensor-node-a','28AA000000000001','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',200,-11.5,'C','ok',now()-interval '12 minutes','synced',6000000,false,now()-interval '12 minutes');
  PERFORM evaluate_alarms();
  IF (SELECT state FROM alarm_state WHERE channel_id='freezer-a') <> 'ALARM' THEN
    RAISE EXCEPTION 'recovered before hysteresis';
  END IF;
  INSERT INTO measurements(node_id,sensor_id,boot_id,seq,value_c,unit,quality,measured_at,time_quality,uptime_ms,buffered,received_at)
  SELECT 'sensor-node-a','28AA000000000001','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
         201+n,-12.5,'C','ok',now()-(10-n*5)*interval '1 minute','synced',n*300000,false,
         now()-(10-n*5)*interval '1 minute'
  FROM generate_series(0,2) n;
  PERFORM evaluate_alarms();
  IF (SELECT state FROM alarm_state WHERE channel_id='freezer-a') <> 'NORMAL' THEN
    RAISE EXCEPTION 'hysteresis recovery failed';
  END IF;
  IF (SELECT count(*) FROM alarm_events WHERE event='RECOVERED' AND channel_id='freezer-a') <> 1 THEN
    RAISE EXCEPTION 'recovery notice count';
  END IF;
  UPDATE measurements SET received_at=received_at-interval '30 minutes' WHERE sensor_id='28AA000000000001';
  PERFORM evaluate_alarms();
  PERFORM evaluate_alarms();
  IF (SELECT count(*) FROM alarm_events WHERE event='STALE' AND channel_id='freezer-a') <> 1 THEN
    RAISE EXCEPTION 'stale notice count';
  END IF;
  result := ingest_measurement(topic, (payload || jsonb_build_object('seq',2,'value',-18.0))::text);
  IF result->>'result' <> 'stored' THEN RAISE EXCEPTION 'restored data ingest'; END IF;
  PERFORM evaluate_alarms();
  IF (SELECT count(*) FROM alarm_events WHERE event='DATA_RESTORED' AND channel_id='freezer-a') <> 1 THEN
    RAISE EXCEPTION 'data restored notice count';
  END IF;
  UPDATE nodes SET availability='offline',last_status_at=now()-interval '20 minutes' WHERE node_id='sensor-node-a';
  PERFORM evaluate_alarms(); PERFORM evaluate_alarms();
  IF (SELECT count(*) FROM alarm_events WHERE event='NODE_OFFLINE') <> 1 THEN
    RAISE EXCEPTION 'node offline notice count';
  END IF;
  UPDATE nodes SET availability='online',last_status_at=now() WHERE node_id='sensor-node-a';
  PERFORM evaluate_alarms();
  IF (SELECT count(*) FROM alarm_events WHERE event='NODE_ONLINE') <> 1 THEN
    RAISE EXCEPTION 'node online notice count';
  END IF;
  IF (SELECT count(*) FROM notification_outbox) <> (SELECT count(*) FROM alarm_events) THEN
    RAISE EXCEPTION 'outbox event mapping';
  END IF;
  IF position('Freezer A' in daily_summary((now() AT TIME ZONE 'Europe/Prague')::date))=0 THEN
    RAISE EXCEPTION 'daily summary missing channel';
  END IF;
  IF position('time,' in daily_csv((now() AT TIME ZONE 'Europe/Prague')::date))<>1 THEN
    RAISE EXCEPTION 'CSV header';
  END IF;
END $$;
INSERT INTO bot_users(chat_id,name) VALUES (1001,'Synthetic operator');
DO $$
DECLARE
  input jsonb;
  r record;
  reply_count int;
  seen_status boolean := false;
  seen_denied boolean := false;
  seen_help boolean := false;
BEGIN
  input := jsonb_build_object('result',jsonb_build_array(
    jsonb_build_object('update_id',1,'message',jsonb_build_object('chat',jsonb_build_object('id',1001),'date',extract(epoch from now())::bigint,'text','/status')),
    jsonb_build_object('update_id',2,'message',jsonb_build_object('chat',jsonb_build_object('id',1002),'date',extract(epoch from now())::bigint,'text','/status')),
    jsonb_build_object('update_id',3,'message',jsonb_build_object('chat',jsonb_build_object('id',1001),'date',extract(epoch from now())::bigint,'text','/unknown'))));
  reply_count := 0;
  FOR r IN SELECT * FROM bot_process(input) LOOP
    reply_count := reply_count+1;
    IF r.to_chat=1001 AND r.reply LIKE '%Сейчас%' THEN seen_status := true; END IF;
    IF r.to_chat=1002 AND r.reply LIKE '%Нет доступа%' THEN seen_denied := true; END IF;
    IF r.to_chat=1001 AND r.reply LIKE '%Команды:%' THEN seen_help := true; END IF;
  END LOOP;
  IF reply_count<>3 THEN RAISE EXCEPTION 'bot reply count'; END IF;
  IF NOT (seen_status AND seen_denied AND seen_help) THEN RAISE EXCEPTION 'bot reply content'; END IF;
  IF (SELECT count(*) FROM bot_process(input))<>0 THEN RAISE EXCEPTION 'bot duplicate update'; END IF;
  IF (SELECT count(*) FROM bot_requests WHERE allowed)<>2
     OR (SELECT count(*) FROM bot_requests WHERE NOT allowed)<>1 THEN
    RAISE EXCEPTION 'bot request log';
  END IF;
END $$;
SELECT 'PASS: SQL assertions' AS result;
