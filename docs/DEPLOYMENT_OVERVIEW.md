# Deployment Overview

Generic process; no site-specific values.

## 1. Approach

- **Bench first, on the real hardware.** The server, cameras, router, AP
  and sensor node were wired up on a bench and taken through every stage
  before going to the site.
- **One small step at a time**, each with a prepared command block, the
  real output pasted back, a review, and a recorded result with its
  evidence level. Larger changes were drafted as written tasks for an AI
  coding assistant, reviewed, and then applied by the owner.
- **Backup before change**: router exports before firewall work, `.env`
  copies before secret changes, Safe Mode on the routers for risky edits.
- **Pinned versions** for every container image; upgrades are deliberate.

## 2. Stages and gates

| Stage | Gate to pass |
| --- | --- |
| Server commissioning | OS installed, GPU visible, disks mounted by UUID and surviving reboot, SMART healthy |
| Container runtime | Docker + Compose, NVIDIA Container Toolkit test, health checks |
| Backend services | PostgreSQL with separate DB roles, Mosquitto with users and ACLs, n8n with 2FA; reboot test — all healthy |
| Network | five networks, default deny, positive and negative tests from each network |
| Cameras | fixed addresses, no internet, dedicated RTSP user, `ffprobe` of both streams with audio |
| Frigate | live view; detection on GPU; event recording with audio; MQTT events; 30 min of clean logs |
| Telemetry | contract agreed; end-to-end with ACK; alarm, offline and report tests |
| Remote access & watchdog | tunnel from laptop and phone; outage test with the watchdog |
| Operations | first backup verified and decrypted off-site; power-loss test |
| **Site** | cabling, camera positions and lighting, site uplink, re-test of tunnel/watchdog, storage re-measure, face-recognition acceptance — **pending** |

## 3. Pre-installation checklist (current)

- [x] Firmware power-on after power loss
- [x] Full verified backup before transport, encrypted copy off-site
- [ ] Site internet: uplink port and addressing checked (no overlap with
      internal networks)
- [ ] Legal: surveillance signage and employee notice; legal review before
      face recognition is used on employees
- [ ] Power: stability confirmed, UPS decision
- [ ] Physical survey: server location, cable routes, AP position for IoT
      coverage at the freezer rooms, probe entry into the freezers

## 4. After installation

System disk image to a separate disk; one week of storage measurement;
lighting experiments at the doors; enabling freezer alarms once probes are
installed; face-recognition acceptance tests.
