# Architecture

Generic description of the platform. No real addresses, identifiers or
site details are used; placeholders are written as `<like-this>`.

## 1. Scope and constraints

- **One site, one edge server.** Everything that touches video, faces and
  sensor data runs on premises. The cloud is used only for notifications
  (Telegram) and an off-site watchdog/backup receiver.
- **Growth path 2 → 4 → 8 cameras** without redesign. The first two cameras
  watch the freezer-room doors; later cameras cover entrances/exits (with
  vehicles and licence plates), the production hall and the packing hall.
- **No inbound internet exposure.** No port forwarding to the site; all
  remote paths are outbound from the site.
- **Identity is a protected data domain.** Reference faces, embeddings,
  recognised names and named clips are treated separately from ordinary
  recording metadata (backup, retention, access, deletion).

## 2. Layers

```text
+------------------------ Camera & edge-inference layer -----------------------+
| IP cameras -- RTSP main/sub --> go2rtc (inside Frigate) --> Frigate          |
|                                    detect (GPU) · record by event · faces    |
|                                    +-> event recordings on the video HDD     |
+------------------------------------------------------------------------------+
+------------------------ Sensor & telemetry layer ----------------------------+
| ESP32 + DS18B20 probes -- isolated IoT Wi-Fi -- MQTT --> Mosquitto           |
+------------------------------------------------------------------------------+
+------------------------ Automation & orchestration layer --------------------+
| Mosquitto --> n8n --> PostgreSQL (ingest, alarm engine, reports)             |
|                n8n --> Telegram (alarms, daily summary)                      |
|                n8n --> heartbeat --> off-site watchdog (over VPN)            |
| Bot polling service <--> PostgreSQL / Telegram (/status)                     |
+------------------------------------------------------------------------------+
```

## 3. Components

| Component | Runs as | Role |
| --- | --- | --- |
| Frigate 0.18 (TensorRT image) | Docker container with GPU | Restream (built-in go2rtc), detection, event recording, snapshots, face recognition, MQTT events |
| Mosquitto 2.0 | Docker container | MQTT broker; per-client users and topic ACLs; listener reachable from the IoT network only for the telemetry port |
| PostgreSQL 16 | Docker container | Separate databases for n8n and for telemetry; telemetry logic in PL/pgSQL |
| n8n 2.x | Docker container | Ingestion with acknowledgement, alarm delivery, daily report, heartbeat |
| Report/archive script | systemd timers | Daily CSV + summary files, monthly archive with a database dump to Telegram |
| Bot polling service | systemd service | Long-polls Telegram for commands; logic and allow-list in the database |
| Backup tooling | systemd timers | Daily logical backup, off-site send with retry, staleness check |

All containers use pinned image versions, health checks, and bind/volume
storage on the SSD — except recordings and the face library, which live on
the dedicated video HDD. Web UIs (Frigate, n8n) listen only on the server's
loopback interface and are reached through an SSH tunnel.

## 4. Data flows

**Video.** Each camera exposes a high-resolution main stream and a low
resolution substream. go2rtc keeps one session per camera stream and fans it
out: the substream feeds detection (848×480 at 5 fps), the main stream is
recorded only around events. Recordings keep camera audio, transcoded to
AAC for MP4 compatibility.

**Detection events.** Frigate publishes events over MQTT; n8n subscribes
read-only. Face matches are attached to the event as a sub-label.

**Telemetry.** The ESP32 node measures every 5 minutes and publishes one
message per probe. n8n validates and stores it through a database function
and publishes an acknowledgement so the device knows the reading was
accepted. The alarm workflow evaluates the state machine every 5 minutes and
delivers queued notifications from an outbox.

**Heartbeat.** Every 5 minutes n8n posts a small status (age of the last
reading, node online, open alarms) through the VPN to an off-site watchdog.
Silence for more than 15 minutes means the site — power, internet, router,
server or n8n — is down, and the watchdog alerts.

## 5. Design principles

- **Event recording, not continuous.** Storage scales with activity, not
  with time; continuous recording stays a per-camera option.
- **Logic close to the data.** Validation, idempotency, the alarm state
  machine and report text live in the database, so n8n workflows stay thin
  and the logic is testable in isolation (see
  [samples/telemetry-db](../samples/telemetry-db/README.md)).
- **Outbox pattern for notifications.** Alarms are rows first, messages
  second; a Telegram outage delays delivery but never loses an alarm.
- **Contract first for devices.** Firmware and platform evolve separately
  against a versioned MQTT contract (see
  [samples/mqtt-contract](../samples/mqtt-contract/README.md)).
- **Least privilege everywhere.** Dedicated RTSP user per camera, per-client
  MQTT users with ACLs, read-only router user for configuration export,
  per-network firewall rules with default deny.
- **Every claim has an evidence level**, and the status is stated honestly
  (bench, not production).

## 6. Related documents

- [CAMERA_AND_EDGE_INFERENCE.md](CAMERA_AND_EDGE_INFERENCE.md)
- [TELEMETRY_AND_AUTOMATION.md](TELEMETRY_AND_AUTOMATION.md)
- [NETWORK_DESIGN.md](NETWORK_DESIGN.md)
- [OPERATIONS_AND_RECOVERY.md](OPERATIONS_AND_RECOVERY.md)
