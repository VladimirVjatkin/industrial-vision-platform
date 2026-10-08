# Network Design

Segmentation is described as a set of decisions and the reasons for them.
Real VLAN IDs, subnets, addresses, hostnames and VPN parameters are
intentionally not published.

## 1. Topology

```text
ISP line -- ISP modem/router -- MikroTik hEX S (router, firewall, DHCP/DNS/NTP, VPN)
                                   +-- SERVER   -- edge server
                                   +-- CAMERA   -- PoE switch -- cameras
                                   +-- trunk    -- MikroTik hAP ac lite (AP)
                                   |                 +-- OFFICE Wi-Fi + ports
                                   |                 +-- IoT Wi-Fi (client isolation)
                                   +-- OFFICE   -- admin workstation
                                   +-- MGMT     -- network device management
```

## 2. Networks and what each may do

| Network | Members | Allowed to | Not allowed to |
| --- | --- | --- | --- |
| MGMT | router/AP management | reach all internal networks, internet | — |
| SERVER | edge server | cameras (RTSP), internet (updates, notifications) | office, IoT |
| CAMERA | cameras, PoE switch | router services (DHCP, DNS, NTP) | **internet**, other networks |
| OFFICE | workstations, office Wi-Fi | internet; **only the admin workstation** reaches the server | cameras, IoT, management |
| IoT | ESP32 nodes (isolated Wi-Fi) | **only the MQTT port on the server** | internet, each other, other networks |

Everything not listed is dropped by a default-deny rule per source network.

**Why**:

- **Cameras without internet** remove the most common CCTV risk (devices
  phoning home, cloud accounts, firmware backdoors) and make the firewall
  drop counter a cheap anomaly signal.
- **IoT reaches exactly one port.** A compromised sensor node can talk MQTT
  with its own restricted broker account and nothing else; Wi-Fi client
  isolation stops nodes from seeing each other.
- **Admin access is a named list, not a network.** Only listed admin hosts
  may open router management or the server; an ordinary office PC on the
  same network cannot.
- **Management on its own network**, reachable from admin hosts and the
  VPN; MAC-level management access is limited to the management network.

## 3. Access point as a pure layer-2 device

The access point carries office and IoT Wi-Fi as tagged VLANs on one trunk
to the router: no DHCP, NAT or routing of its own, management only on the
management VLAN, IoT SSID with client isolation. Its factory configuration
(DHCP server and client, NAT, leftover firewall rules) was removed in Safe
Mode after a backup. Its old firmware (2016) was upgraded offline before it
was configured.

## 4. Remote access: outbound VPN only

- The site router **dials out** with WireGuard to an off-site VPN hub; no
  port is opened at the site, so the site works behind the ISP's NAT.
- Through the tunnel, **only the owner's devices** may reach: the router
  and AP management, and the server **over SSH only**. Web UIs (Frigate,
  n8n, camera pages) are reached by SSH port forwarding. Cameras, IoT,
  office devices and the site's internet uplink are dropped for tunnel
  traffic by an explicit rule.
- The hub forwards to the site only from the owner's devices; the site
  cannot reach the hub's own network, its other VPN peers or its services —
  except the heartbeat receiver and the backup receiver, each opened for the
  server's address and one port.
- Finding during setup: before the explicit drop, tunnel traffic would have
  been forwarded anywhere, because the default-deny rules matched only
  local source networks. The fix was an explicit "deny from tunnel" rule
  right after the tunnel allow-rules.

## 5. Time

The router synchronises with internet NTP and serves time to cameras,
the AP and sensor nodes. The server uses internet NTP directly. The router
has no battery-backed clock, so it relies on NTP after every power loss
(verified after a power-off test).

## 6. Verified (`owner-reported`, bench)

- Office clients: internet OK; ordinary office client → server, router
  management: blocked; admin workstation → server and router: OK.
- IoT client: DHCP/DNS OK; internet blocked (drop counter grows); server
  SSH, camera RTSP, router management blocked; MQTT port allowed.
- Cameras: DHCP leases bound; camera → internet attempts dropped.
- VPN from a laptop and a phone on mobile data: router, AP and server SSH
  reachable; nothing else.
- Router power-off test: tunnel, time and telemetry recovered by themselves.
