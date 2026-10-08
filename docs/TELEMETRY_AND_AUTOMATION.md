# Telemetry and Automation

ESP32 temperature node → MQTT → n8n → PostgreSQL → alarms and reports in
Telegram. Runnable version of the database part:
[samples/telemetry-db](../samples/telemetry-db/README.md). Message contract:
[samples/mqtt-contract](../samples/mqtt-contract/README.md).

## 1. Scope

One ESP32 node with three DS18B20 probes: two freezer rooms and the
production-hall air. Measurement every 5 minutes. Storage keeps raw
5-minute readings plus 30-minute minima (which filter short defrost
peaks in reports), with a retention target of at least 3 years.

## 2. Flow

```text
ESP32 --publish--> measurement / status / availability (MQTT, QoS 1)
          <-ack---- n8n "ingest": validate + store via DB function, publish ACK
n8n "alarms" every 5 min: evaluate state machine → outbox → Telegram → mark sent
n8n "daily" 08:00:   yesterday's summary → Telegram
timer 08:05:         daily CSV (30-min minima) + summary file on the server
timer 1st, 08:30:    monthly zip (files + database dump) → Telegram
n8n "heartbeat" every 5 min → off-site watchdog over VPN
```

- **Idempotency**: each reading carries the node boot ID and a sequence
  number; duplicates are accepted but stored once, and still acknowledged.
- **Application-level ACK**: the node learns that a reading was *stored*,
  not just delivered to the broker — the basis for its local buffering.
- **Time quality**: live readings are timed by the server on receipt;
  readings buffered on the node keep their own timestamp only if the node's
  clock was synchronised when they were taken.

## 3. Alarm policy

| Channel | Normal range | Alarm |
| --- | --- | --- |
| Freezer rooms | −25 … −11 °C | outside range for 20 min |
| Production-hall air | +6 … +35 °C | outside range for 20 min |

- **States**: NORMAL → PENDING (out of range) → ALARM after the hold time;
  back to NORMAL only after 10 minutes inside the range **with 1 °C of
  hysteresis**, so a value hovering at the limit does not flap.
- **Reminder** every hour while an alarm is open.
- **Stale data**: no reading for 15 minutes → "no data" notice, and "data
  restored" when it returns.
- **Node offline**: the whole node silent for 15 minutes → one node notice
  instead of one per probe.
- **Per-channel switch**: alarms can be disabled per channel (e.g. freezer
  probes on the bench at room temperature); disabling clears an open alarm
  silently.
- Evaluation is a single database function called by n8n; n8n only
  delivers what the outbox holds.

## 4. Reports

- **08:00 Telegram summary** of yesterday: average/min/max per channel, time
  above/below limits, data completeness, alarms and outages.
- **Daily files** on the server: CSV of 30-minute minima + text summary,
  organised by year/month.
- **Monthly archive** to Telegram: the month's files plus a full database
  dump — a simple off-server copy for the operator.

## 5. `/status` command

Users send `/status` to the alarm bot and receive current temperatures,
the age of each reading, alarm state and range, node link and open alarms.

- A small **systemd service long-polls** the Telegram Bot API (no webhook,
  so no inbound port and no public URL).
- The service only moves JSON; the **allow-list, request log, command
  routing and reply text are in the database** — new commands are SQL
  functions.
- Unknown users get "no access" with their chat ID, which the owner can add
  with one SQL statement. Alarm messages go to a separate, explicitly
  configured recipient list.

## 6. What was verified (`owner-reported`, bench)

| Check | Result |
| --- | --- |
| End-to-end: ESP32 → MQTT → n8n → PostgreSQL → ACK | every 5 min, clock-synchronised readings |
| PENDING → ALARM | after exactly the 20-minute hold time |
| Node offline / back online notices | both delivered |
| Daily summary, daily files, monthly archive with dump | delivered / written |
| Restore of the monthly dump into a fresh database | worked after a fix (below) |
| `/status` for allowed and unknown users | correct reply / "no access" with ID |
| Alarm delivery to a second recipient | both received, sent once |

Not yet observed on real freezers: the recovery ("back to normal") message
and alarms on installed probes.

**Finding from the restore test.** The first restore of a dump brought the
data back, but the report functions failed: they relied on a per-role
`search_path` setting, which is stored outside the database and therefore
not in the dump. Fix: the search path is pinned on every function, so the
dump is self-contained. A restore test that only checks row counts would
have missed this.
