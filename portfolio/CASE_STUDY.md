# Case Study: An Edge Vision and Telemetry Platform, Built on a Bench

## Context

A production site in Czechia — production and packing halls, freezer
rooms, entrances and exits — wanted local video surveillance that
understands what it sees, plus reliable freezer temperature alarms. Video
and biometrics had to stay on site, and the site must not be exposed to the
internet. The target is 8 cameras; the first two watch the freezer-room
doors.

I designed the system, chose the hardware, and built and tested it on a
bench with the real server, cameras, router, access point and sensor node,
before installing it on site. AI tools (Claude, Codex, ChatGPT) were used
for analysis, implementation drafts and documentation; architecture,
requirements, validation and deployment decisions stayed with me.

Status: **bench-tested, site installation in progress, not production.**

## Decisions that shaped the system

**1. Event recording on a local GPU, not a cloud NVR.**
Frigate with person detection on an RTX 3050 records only when a person is
present, with a few seconds of pre-capture and the camera's audio. That
makes ≥ 50 days of retention for 6–8 cameras realistic on one 4 TB disk —
and I measured it rather than trusting a calculator: after a week, two
cameras used ~1.6 GB/day at ~1.5 Mbit/s, which gives a capacity model in
"recorded hours per camera per day" that can be re-checked on site.

**2. One RTSP session per camera.**
go2rtc inside Frigate pulls each stream once and serves detection,
recording and live view from it. The substream (848×480 at 5 fps) is enough
for person detection at ~19 ms per inference; the main stream is touched
only around events.

**3. Faces are a separate data domain.**
Native face recognition worked on the bench with consenting test persons,
but I did not call it done: acceptance needs measured passes per camera,
day vs infrared, and proper lighting at the doors — and enrolling
employees needs a legal basis first. Reference faces, embeddings and named
events are backed up separately and never appear in Git or documentation.

**4. The device and the platform meet at a contract.**
The ESP32 firmware is a separate project. Instead of sharing code, I wrote
a versioned MQTT contract: topics, payloads, QoS, time quality, and an
application-level acknowledgement so the node knows a reading was stored,
not just delivered. Duplicates are expected and stored once.

**5. Alarm logic lives in the database.**
The state machine — pending, alarm after 20 minutes, recovery only after
10 minutes inside the range with 1 °C hysteresis, hourly reminders, stale
data, node offline — is PL/pgSQL. n8n just calls it and delivers an outbox.
That made the logic testable on its own
([samples/telemetry-db](../samples/telemetry-db/README.md)) and meant a
Telegram outage could delay an alarm but never lose it.

**6. No inbound ports, ever.**
Five networks with default deny; cameras and IoT nodes have no internet;
IoT reaches exactly one broker port. Remote administration is an outbound
WireGuard tunnel to an off-site hub, through which only my own devices
reach router management and server SSH. Even the Telegram `/status` command
is served by long polling instead of a webhook.

**7. Assume the site will go dark.**
A heartbeat every 5 minutes to an off-site watchdog catches what the site
cannot report itself: power, uplink, router, server or n8n failure. I tested
it by switching the router off: the alert came after 19 minutes of silence,
and the recovery message when it came back.

## Validation that found real problems

The most useful tests were the ones that failed first:

- **Tunnel traffic was forwarded everywhere.** The router's default-deny
  rules matched only local networks, so packets arriving from the VPN had
  no final drop. Found by reading the rule set before opening access; fixed
  with an explicit deny-from-tunnel rule.
- **A restored database that did not work.** The monthly dump restored all
  data, but the reports failed: functions depended on a role setting that a
  dump does not contain. A row-count check would have passed. I pinned the
  search path inside every function, re-tested on a fresh dump, and made a
  weekly automatic restore test run a real report.
- **A read-only account that could read Wi-Fi keys.** The router-config
  backup used a read-only account, but the older RouterOS version still
  printed Wi-Fi keys in its export. I checked the export for key fields
  without printing them, switched that router to a secret-hiding export,
  and made the backup reject any export that still contains a secret field.
- **A nightly gap in off-site backups.** On the bench the site sits behind a
  network with a nightly internet block, so the 02:30 off-site copy failed.
  Instead of moving the schedule, I added an hourly retry with send-once
  markers — the same failure mode will happen on site during an ISP outage.
- **A server that switched itself off.** Two unexplained stops: journal and
  router uptime showed a server-only power loss; a loose power cable was
  the likely cause. Outcome: persistent journal, minute-level metrics,
  firmware power-on after power loss (tested by pulling the plug), and the
  watchdog.

## Operations from day one

Daily backups to two disks with integrity checks, an encrypted off-site
copy whose key exists only with me, monthly USB copies, router configs
without secrets, SMART alerts, staleness alerts against a 24-hour recovery
point objective, and one short recovery procedure per failure (SSD, HDD,
GPU, mainboard, router, camera). The first backup was decrypted on my laptop
to prove the chain works before anything else depended on it.

## What is still open

Site installation and re-tests, face-recognition acceptance and lighting,
storage re-measurement under real activity, more cameras with vehicle and
licence-plate detection, a full restore rehearsal on separate hardware.

## What this demonstrates

Edge AI is mostly systems engineering: a model running at 19 ms is the easy
part. The work is in stream handling, storage that is measured, data that
is protected by design, devices that agree on a contract, logic that can be
tested, networks that deny by default, and operations that assume failure —
and in being honest about what has and has not been proven yet.
