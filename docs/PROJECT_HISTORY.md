# Project History

The platform was built in about two and a half weeks of bench work on the
real hardware, after an earlier design period (requirements, network
baseline on the router, hardware purchase). Dates are bench dates.

| When | Milestone |
| --- | --- |
| Before | Requirements and architecture; router segmentation baseline; hardware selected and purchased; current-state audit of earlier experiments with Frigate and ESP32 sensors |
| Day 1–2 | Server commissioned: Ubuntu, NVIDIA driver and container toolkit, video HDD by UUID; PostgreSQL, Mosquitto, n8n deployed with health checks; reboot test |
| Day 3 | Server and first camera moved into their networks; router NTP; camera addressing convention; first stream probed |
| Day 4 | Frigate with built-in go2rtc: live view of both cameras |
| Day 5 | GPU person detection (YOLOv8n ONNX), event recording with audio, 50-day retention, MQTT events; dedicated RTSP user; face recognition bench test started |
| Day 6–7 | Access point: firmware from 2016 upgraded offline, rebuilt as a layer-2 AP with office and isolated IoT Wi-Fi; admin access narrowed to named hosts; server power incident investigated (monitoring added, loose power cable found) |
| Day 7 | MQTT broker opened to the IoT network for one port; telemetry ACLs |
| Day 8–9 | MQTT contract; telemetry database; n8n ingestion with ACK; first end-to-end readings from the ESP32 |
| Day 10–11 | Alarm state machine, Telegram alarms, offline notices, range limits per channel; daily summary, daily files, monthly archive with database dump |
| Day 12 | Outbound WireGuard tunnel for administration; external heartbeat watchdog; router outage test |
| Day 13 | 7-day storage measurement; restore test of the database dump (and the fix it revealed); `/status` bot command; alarm delivery to a second recipient |
| Day 14 | Backup and recovery tooling and procedures; first verified backup, decrypted off-site; firmware power-on after power loss |
| Day 15 | Router configuration export without secrets; off-site receiver; hourly retry for off-site copies |
| Next | Site survey and installation; site re-tests; lighting and face-recognition acceptance; more cameras |

## How the work was done

- Owner-driven: requirements, architecture and every decision were made by
  the owner; every command on the hardware was run by the owner.
- AI-assisted engineering: Claude (analysis, architecture review, prompts,
  documentation, review of outputs), Codex (implementation drafts and
  reviews from written task specifications) and ChatGPT were used as tools.
- Firmware for the sensor node is developed as a separate project; the two
  projects exchange requirements and status through numbered written
  messages and a shared, versioned contract — see the
  [ESP32 case study](../portfolio/ESP32_CASE_STUDY.md).
