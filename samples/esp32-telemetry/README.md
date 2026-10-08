# Host-testable temperature telemetry core

This is an independently rewritten C sample of device-side temperature
telemetry logic. It demonstrates v1 measurement and status JSON, synthetic
boot UUID generation from caller-provided entropy, per-sensor sequence
numbers, a bounded RAM queue with oldest-first eviction, resend flags, and
application ACK validation. It uses no ESP-IDF headers, hardware, MQTT
client, NVS, or network connection. Its contract companion is
[the MQTT sample](../mqtt-contract/README.md); the receiving database is
shown separately in [the SQL sample](../telemetry-db/README.md).

The system was designed and built by the owner with AI-assisted engineering
tools (Claude, Codex, ChatGPT). The owner retained architecture,
requirements, validation, and deployment decisions. This public code was
written independently to demonstrate those concepts; it is not a copy of
the device firmware.

## Build and test on a PC

Requires Python 3 and a C compiler (`gcc`, `clang`, or MSVC). From this
directory:

```sh
python tests/run.py
```

The runner compiles the two C files in a temporary directory, runs the
assertions, and leaves no build output in the sample. It has been run with
MSVC on Windows and with gcc 14 (`-std=c11 -Wall -Wextra -Werror -pedantic`)
in a Linux container. On Unix-like systems it uses `-std=c11 -Wall -Wextra
-Werror -pedantic`. The tests cover boot UUID format, per-probe sequences,
input validation, value and time quality, stable resend content, JSON
escaping, capacity eviction, failed-publish retry, status/availability,
matching and malformed ACKs, duplicate ACKs, and a new boot identity.

## Integration boundary

The host provides fresh random bytes on every boot and captures UTC time
when SNTP has synchronized. `tlm_enqueue` freezes a reading and assigns its
sequence number. A transport adapter calls `tlm_prepare_next` before
publishing, then calls `tlm_publish_failed` if the publish request fails.
`at_capture` is true only for an immediate first send. Later sends retain
the original reading and use `buffered: true`. The adapter passes a bounded
flat JSON ACK to `tlm_handle_ack_json`; only a matching `stored`,
`duplicate`, or `rejected` result removes the record. MQTT PUBACK is
deliberately outside this API.

The caller must serialize access if capture, MQTT callbacks, and draining
run on different threads. This sample uses a 16-record maximum for concise
host tests; a device chooses its own capacity according to available RAM.
The queue is volatile, so it cannot guarantee delivery across power loss.
The strict ACK parser accepts only the five documented fields and rejects
escaped strings or extra fields. A production transport can use a proven
JSON library and pass the same validated fields to its queue logic.

## Sanitization and evidence

| Private category | Public replacement |
| --- | --- |
| Real node and probe identifiers | `sample-node-a` and invented ROM-format strings |
| Actual boot IDs and telemetry | Deterministic synthetic test bytes and values |
| Wi-Fi, broker, network, and NVS settings | Omitted; no credentials or addresses |
| Platform and device paths, logs, build products | Omitted |

The code and host tests prove only this rewritten sample. The actual device
and end-to-end delivery have owner-reported bench results, including a short
outage test. Queue overflow, rejected ACKs on hardware, and production
operation remain unverified. The platform is installation in progress.
