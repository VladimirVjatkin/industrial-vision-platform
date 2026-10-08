# MQTT temperature telemetry contract (public sample)

This is a sanitized v1 contract for a bench-tested temperature pipeline. It describes the messages exchanged by a sensor node, broker, and database ingestion workflow. The examples are synthetic; they are not captured traffic. Installation is in progress and no production acceptance is claimed.

The design and system were built by the owner with AI-assisted engineering tools (Claude, Codex, ChatGPT). The owner retained responsibility for architecture, requirements, validation, and deployment decisions.

## Transport and topics

MQTT 3.1.1, stable client ID per node, 60-second keepalive, persistent session for the node's QoS 1 acknowledgement subscription. The broker requires an authenticated per-node identity; this sample contains no broker address or credential. A deployment must provide its own transport protection and access rules.

| Topic under `ivp/telemetry/v1` | Direction | QoS | Retained | Payload |
| --- | --- | ---: | --- | --- |
| `nodes/<node-id>/sensors/<sensor-id>/measurement` | node to workflow | 1 | no | JSON measurement |
| `nodes/<node-id>/status` | node to workflow | 0 | yes | JSON heartbeat, about every 60 seconds |
| `nodes/<node-id>/availability` | node to workflow | 1 | yes | Plain `online` or `offline` |
| `nodes/<node-id>/ack` | workflow to node | 1 | no | JSON database acknowledgement |

The node configures a retained `offline` last will and sends `online` after connecting. A retained `online` is not proof of freshness; the workflow also checks heartbeat age. Node identities can write only their own measurement, status, and availability topics, and read only their own acknowledgement topic. The ingestion identity reads telemetry and writes acknowledgements.

## Identifiers and message rules

`node_id` matches `[a-z0-9-]{3,32}`. `sensor_id` is a 16-character uppercase hexadecimal DS18B20 ROM. `boot_id` is a new UUID v4 on every boot. `seq` starts at zero and increases independently for each sensor within a boot. The physical ROM maps to a logical channel on the server, so a probe replacement can preserve channel history.

All JSON examples are in [`examples/`](examples/). Run `python validate.py` to validate them with the Python standard library.

Measurement fields: `schema_version` (integer `1`), `node_id`, `sensor_id`, `boot_id`, `seq` (nonnegative integer), `measured_at` (UTC timestamp or null), `uptime_ms` (nonnegative integer), `value` (finite number from -55 to 125 or null), `unit` (`C`), `quality` (`ok`, `not_found`, `crc_error`, `conversion_timeout`, `suspect`), `time_quality` (`synced`, `estimated`, `unsynced`), `buffered` (boolean), and `firmware_version`. Unknown optional fields are ignored. A numeric value requires `ok` or `suspect`; `ok` requires a numeric value. A failed probe read sends null, never a placeholder zero or -127. A persistent +85 °C with valid conversion and CRC may be marked `suspect`.

Status fields: `schema_version`, `node_id`, `boot_id`, `uptime_ms`, `time_quality`, `wifi_rssi`, `sensors_found`, `buffer_depth`, `buffer_dropped`, and `firmware_version`. `buffer_dropped` is cumulative since boot.

Acknowledgement fields: `schema_version`, `sensor_id`, `boot_id`, `seq`, and `result` (`stored`, `duplicate`, `rejected`). The workflow publishes an acknowledgement only after the database transaction commits. A node removes a buffered measurement after any of those three results; a resend retains its original key.

## Time and idempotency

The database key is `(node_id, sensor_id, boot_id, seq)`. Repeated content returns `duplicate`; a repeated key with different content is rejected and logged. Content comparison covers value, unit, quality, measured timestamp, time quality, and uptime. A resend may change `buffered` and firmware metadata. The first immediate send has `buffered=false`; delayed first sends and retransmissions have `buffered=true`. MQTT library QoS 1 retransmission within the same publish attempt does not change this field.

Live messages use server `received_at` for alarm time. Buffered messages use their measured timestamp only when clock quality is acceptable; unsynced buffered data is stored without confirming or clearing an alarm. Firmware currently sends `synced` or `unsynced`; `estimated` is reserved by the contract. Unsynced measurements keep `measured_at=null` across retransmissions.

The major version appears in the topic and `schema_version`. Compatible optional additions retain v1. A changed topic, required field, or meaning requires v2; unknown major versions are rejected.

## Sanitization and evidence

Device IDs, ROMs, timestamps, and payload values in this sample are invented. Broker address, network topology, user names, and credentials are omitted. The private bench has owner-reported end-to-end telemetry and alarm checks; this file proves only that the public examples pass the included offline validator. It does not prove broker delivery, firmware behavior, or production operation.
