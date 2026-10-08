# Camera Ingestion and Edge Inference

## 1. Cameras

| Item | Choice | Reason |
| --- | --- | --- |
| Model (first two) | TP-Link VIGI C250, 4 mm, 5 MP | One procurement line; RTSP/ONVIF; microphone; IR night mode |
| Main stream | H.264, 2880×1620, 25 fps, VBR (max ~6 Mbit/s) | Recording and identification; plain H.264 because "H.264+"-style smart codecs stretch keyframe spacing and hurt segmenting and seeking |
| Substream | H.264, 848×480, 25 fps, CBR | Detection input and live overview |
| Audio | G.711 A-law from the camera → AAC in recordings | The camera offers no AAC; MP4 recordings need it |
| On-camera recording / detection / cloud | Off | One archive, server-side only; detection belongs to Frigate; no third-party cloud |
| Time | From the site router (NTP) | Consistent timestamps across cameras, server and sensors |
| RTSP account | Dedicated low-privilege user per camera | The admin account is not stored on the server |
| Night mode | Auto IR | No white-light flashes; final lighting is chosen on site |

Cameras sit in their own network without internet access; only the server
may open their RTSP port. The camera web UI is reached through an SSH port
forward via the server when needed — never directly from the VPN.

## 2. Restream: go2rtc inside Frigate

go2rtc runs inside the Frigate container rather than as a separate service.
Each camera stream is pulled once; recording, detection and live view are
all served from that single session, which keeps the load on the cameras
constant as consumers are added.

## 3. Detection on the GPU

| Item | Value | Evidence |
| --- | --- | --- |
| Detector | ONNX on NVIDIA GPU (Frigate TensorRT image) | `locally verified` |
| Model | YOLOv8n, 640×640, exported to ONNX with a pinned toolchain; checksum recorded | `locally verified` |
| Inference time | ~19 ms | `locally verified` |
| Detect input | 848×480 at 5 fps per camera, no skipped frames | `locally verified` |
| VRAM | ~0.4 GB detector; ~0.9 GB with face recognition | `owner-reported` |
| Tracked objects | `person` only on interior cameras | `locally verified` |

Planned: `car` and licence plates on entrance cameras only, with the same
detector.

## 4. Recording and retention

- **Events only**: recording starts on a tracked person, with 5 s pre- and
  post-capture; no continuous archive, no stand-alone motion retention.
- **Retention target ≥ 50 days** for alert/detection recordings and
  snapshots.
- **Audio** is recorded with video (it is sensitive surveillance data and
  follows the video's retention).

### Storage model — measured, not guessed

After 7 days on the bench (two cameras, low activity), `owner-reported`:

| Metric | Value |
| --- | --- |
| Event recordings per day (2 cameras) | ~1.6 GB |
| Average main-stream bitrate during events | ~1.3–1.7 Mbit/s (VBR, with audio) |
| Storage per recorded camera-hour | ~0.6–0.75 GB |

Capacity for 6 cameras on a 3.6 TB disk at that bitrate:

| Person in view, hours/day per camera | Days of retention |
| --- | --- |
| 4 | ~210 |
| 8 | ~105 |
| 16 | ~52 |
| 24 | ~35 |

So the 50-day target holds up to ~16 recorded hours per camera per day.
Busy scenes and night noise raise VBR bitrate, so the numbers are re-measured
after a week of real operation on site. When the disk fills, Frigate deletes
the oldest recordings — retention shrinks, recording does not stop.

## 5. Face recognition — boundaries

Status: **working on the bench, not accepted** (`owner-reported`).

- Engine: Frigate's native face recognition on selected cameras; a separate
  recognition service is an approved fallback only if native recognition
  proves insufficient in measured tests.
- A recognised person is stored as the event's sub-label, searchable in the
  UI and available to automation.
- The **identity domain** — reference images, embeddings, names, recognition
  events, named snapshots and clips — is protected data: never in Git or
  documentation, backed up separately, with an explicit deletion procedure
  for test data.
- Bench tests used only consenting test persons. Enrolling employees
  requires a legal basis and notice first; this is a precondition, not a
  formality.
- Open before acceptance: controlled passes per camera (correct / unknown /
  wrong), daylight vs IR, face size in the detection frame, lighting at the
  doors.

No images, recognition results or screenshots with people are published in
this repository.

## 6. Lighting

Identification at freezer doors depends on light more than on the model.
The decision between the camera's own light, an LED strip and a soft lamp
is deliberately left to on-site experiments after installation; the
cameras stay on Auto IR until then.
