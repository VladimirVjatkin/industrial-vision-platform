# Notice

This repository documents a platform that integrates third-party open-source
software and commercial hardware. None of the third-party components are
included or redistributed here; they are named for attribution and context.

| Component | Role in the platform | Upstream |
| --- | --- | --- |
| Frigate | NVR with object detection, event recording, face recognition | https://github.com/blakeblackshear/frigate (MIT) |
| go2rtc | RTSP restream, built into Frigate | https://github.com/AlexxIT/go2rtc (MIT) |
| Ultralytics YOLOv8n | Person-detection model, exported to ONNX for Frigate | https://github.com/ultralytics/ultralytics (AGPL-3.0) |
| ONNX Runtime | Inference runtime inside Frigate | https://github.com/microsoft/onnxruntime (MIT) |
| Eclipse Mosquitto | MQTT broker | https://github.com/eclipse-mosquitto/mosquitto (EPL-2.0 / EDL-1.0) |
| n8n | Workflow automation | https://github.com/n8n-io/n8n (Sustainable Use License) |
| PostgreSQL | Database | https://www.postgresql.org (PostgreSQL License) |
| age | File encryption for off-site backups | https://github.com/FiloSottile/age (BSD-3-Clause) |
| ESP-IDF | ESP32 firmware framework | https://github.com/espressif/esp-idf (Apache-2.0) |

The YOLOv8n model weights are **not** included in this repository. Its
AGPL-3.0 licence was reviewed and accepted for internal, on-premises use in
the private deployment.

Product names (TP-Link VIGI, MikroTik, HP, NVIDIA, Espressif, Telegram) are
trademarks of their respective owners and are used only to describe the
hardware and services the platform runs on.

No licence is granted for the contents of this repository unless a licence
file is added later; it is published for portfolio review.
