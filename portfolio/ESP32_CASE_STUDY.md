# Mini Case Study: ESP32 Temperature Node

> Public engineering summary. Device and network identifiers are omitted.

## Context

Freezer rooms and the production hall need temperature readings every
5 minutes, delivered reliably to the platform even over a weak Wi-Fi link,
with no internet access for the device.

## Hardware

- ESP32 Audio Kit (ESP32-A1S) running ESP-IDF firmware.
- Up to three DS18B20 1-Wire probes on one bus: two freezer rooms, one
  production-hall air probe.
- Isolated IoT Wi-Fi; the node may reach only the MQTT port of the server.

## From HTTP polling to MQTT push

An earlier version of the firmware served readings over HTTP for polling
and logged to an SD card. For the platform it was changed to publish over
MQTT, against a written, versioned contract
([samples/mqtt-contract](../samples/mqtt-contract/README.md)):

- one measurement message per probe, with node boot ID and sequence number
  for idempotency;
- status and availability messages (last will) for node health;
- an application-level acknowledgement from the platform after the reading
  is stored;
- explicit time quality: readings are only trusted with the device
  timestamp after SNTP synchronisation;
- a missing or failed probe is reported as a status, never as a `0 °C`
  reading.

## Two projects, one contract

The firmware and the platform are separate projects with separate
repositories and change processes. They coordinate through numbered,
append-only written messages (questions, status reports, contract
changes) and the shared contract document, so neither side edits the
other's code.

## Verified on the bench (`owner-reported`)

- Three probes publishing every 5 minutes; readings acknowledged and stored.
- Node offline / back online detected by the platform.
- Internet blocked for the node; MQTT the only allowed path.

## Firmware structure and message handling

The firmware has separate audio and telemetry build profiles. The telemetry
profile includes Wi-Fi, a shared DS18B20 driver, SNTP, MQTT, and a bounded
RAM queue; it does not start the audio or HTTP services. Configuration is read
from a separate NVS partition. If it is missing or invalid, the node keeps
measuring locally without joining the network. The firmware does not erase
that configuration partition.

The sensor registry keeps up to three probe identities seen during a boot.
Each reading is fresh: a failed read carries a quality code and a null value.
A persistent +85 °C reading after a completed conversion and repeat check is
marked `suspect`. A probe never discovered by the node is detected as stale
through its expected server-side channel mapping.

At each boot the node creates a new UUID. It increments a separate sequence
counter for each probe. A measurement captures its value, quality, uptime,
and UTC timestamp once. The first reading waits up to 10 seconds for SNTP;
if time is still unavailable, it sends `measured_at: null` and
`time_quality: unsynced`. Later retransmissions keep the captured content.
The node also publishes a heartbeat and retained availability state; an
MQTT last will announces an unexpected disconnect.

## ACK and outage behaviour

Each measurement enters a RAM queue before publication. MQTT's transport
acknowledgement does not clear it. The device removes a record only after a
matching application ACK from the database workflow: `stored`, `duplicate`,
or `rejected`. Rejected records are counted separately. The ACK handler
checks the schema, probe identity, boot UUID, sequence, and result.

The first immediate send uses `buffered: false`; a delayed send or an
application retry uses `buffered: true`. The application retries after five
minutes and drains at most ten records per sweep. The queue holds 864
measurements, roughly 24 hours at three probes every five minutes. Once
full, it evicts the oldest record and increments a loss counter. The queue
is volatile: a reboot can lose unacknowledged measurements. A short MQTT
library retry belongs to the same initial publish attempt and may retain
`buffered: false`.

The owner reported a bench Wi-Fi outage of about 20 minutes: twelve delayed
measurements arrived with their original timestamps and were acknowledged.
A separate owner-reported database review showed about 44 hours of one boot
with no missing sequence numbers for the three probes. These observations
do not test queue overflow, rejected ACK behaviour on hardware, or
production recovery.

## Lessons and public sample

- Treat database persistence as a separate event from MQTT delivery.
- Record time quality with the reading; do not assign a new timestamp while
  draining a backlog.
- Keep failed sensor values null, including the DS18B20 power-on edge case.
- Count evictions explicitly and state the reboot loss limit of a RAM queue.
- Keep site configuration in a separate provisioned store, outside source
  code and public examples.

The [standalone C sample](../samples/esp32-telemetry/README.md) independently
recreates the message, sequence, queue, and ACK concepts with synthetic
identifiers and host tests. It has no ESP-IDF, Wi-Fi, NVS, sensor bus, or
MQTT client dependency. Its passing tests verify the sample's logic; they
are not device tests. The platform is bench-tested and installation is in
progress, with no production acceptance.

The system was designed and built by the owner with AI-assisted engineering
tools (Claude, Codex, ChatGPT). The owner retained responsibility for the
architecture, requirements, validation, and deployment decisions.
