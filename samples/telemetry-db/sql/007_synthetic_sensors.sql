-- Synthetic probe assignments for the standalone sample.
BEGIN;
SET ROLE telemetry_app;
SET search_path = telemetry;
UPDATE channels SET sensor_id = '28AA000000000001', calibration_offset_c = 0.25 WHERE channel_id = 'freezer-a';
UPDATE channels SET sensor_id = '28AA000000000002' WHERE channel_id = 'freezer-b';
UPDATE channels SET sensor_id = '28AA000000000003' WHERE channel_id = 'workshop';
RESET ROLE;
COMMIT;
