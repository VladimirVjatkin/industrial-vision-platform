# Temperature telemetry database sample

This runnable PostgreSQL sample shows how a sensor message becomes a calibrated reading, an alarm event, a notification-outbox row, a daily report, and an authorized bot reply. It is designed for review in about five minutes.

```sh
docker compose run --rm tests
```

The command starts an isolated PostgreSQL 16.6 container, recreates its sample database, applies migrations in order, runs SQL assertions, makes a `pg_dump`, restores it into a fresh database, and calls restored functions. Containers expose no host database port. The database uses `trust` authentication inside this isolated test network only; do not reuse this compose file for deployment.

## What is included

Migrations `001`–`006` preserve the private bench SQL logic: MQTT JSON validation, idempotency on `(node_id, sensor_id, boot_id, seq)`, logical channel mapping and calibration, 30-minute minimum view, alarm state machine with hold time and hysteresis, node and data availability notices, notification outbox, daily text/CSV reports, a bot allow-list and request log, and function-level pinned `search_path`. Migration `007` assigns invented probe ROMs to the sample channels. No n8n workflow or MQTT broker runs in this sample; in the bench system, n8n passes MQTT payloads into `ingest_measurement` and `ingest_node_message`, schedules `evaluate_alarms`, sends outbox rows, and uses `daily_report` for reports. The bot polling service is represented in the backup/operations sample.

The operator-facing alarm and report strings remain in Russian because the bench operators read Russian. Public documentation and test names are in English.

## Synthetic data and tests

The node, channels, ROMs, boot IDs, chat IDs, messages, and measurements here are invented. Tests cover valid/invalid JSON and payloads, duplicate and conflicting-key handling, calibration, `PENDING` to `ALARM` after the 20-minute hold, hysteresis recovery, stale to restored data, offline to online node transitions, one outbox row per event, daily summary and CSV, allowed/denied/unknown bot commands, duplicate bot updates, and fresh dump/restore with pinned function `search_path`. Time-dependent tests backdate test rows and the pending state; function logic and the system clock are untouched.

## Sanitization and changes

| Source category | Public treatment |
| --- | --- |
| Real node and channel identifiers, display names | Synthetic `sensor-node-a`, `freezer-a`, `freezer-b`, `workshop`, and generic display names |
| Probe mappings | Invented `28AA000000000001`–`003` |
| Private decision and deployment comments | Removed or rewritten as plain engineering comments |
| Owner bot recipients | Synthetic numeric chat IDs in tests only |

Function bodies, table definitions, views, alarm thresholds, and notification text were not intentionally changed. The only data-level change within migrations is the synthetic initial seed: its third channel is a room channel, so the existing range migration applies the room alarm rule. Migration `007` is sample-only sensor assignment. No other non-cosmetic SQL change is intended. The SQL was copied and sanitized, not independently redesigned.

The platform remains bench-tested with installation in progress, not production accepted. Passing these synthetic tests proves behavior of the public SQL sample and dump/restore path under the sample container; it does not establish that every deployed workflow or production alarm is correct. The private bench's end-to-end operation is owner-reported.

The system was designed and built by the owner with AI-assisted engineering tools (Claude, Codex, ChatGPT). The owner retained architecture, requirements, validation, and deployment decisions.
