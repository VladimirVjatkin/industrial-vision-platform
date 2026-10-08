# Operations and Recovery

Tooling: [samples/ops-backup](../samples/ops-backup/README.md).

## 1. External watchdog

A site that loses power or internet cannot report its own outage. The site
therefore **pushes** a heartbeat every 5 minutes (n8n → over the VPN → an
off-site watchdog). The watchdog alerts in Telegram after 15 minutes of
silence, reminds hourly, and confirms recovery.

- The heartbeat endpoint is reachable only through the tunnel and only from
  the site server, and requires a token; it is not reachable from the
  public internet.
- Because the heartbeat is produced by n8n after a database query, it also
  stops when the database, n8n, the server, the router or the uplink fails.

**Test** (`owner-reported`): router powered off for ~20 minutes → "site not
reachable, 19 min" alert; router back → "site back online (silence 25
min)", plus the site's own queued notices delivered on reconnection.

## 2. Power

The server's firmware is set to **power on after power loss** — tested by
cutting mains after a clean shutdown: the server started by itself and all
services came back healthy. A server UPS is a pending purchase decision.

## 3. Backups

| What | How |
| --- | --- |
| PostgreSQL | `pg_dump` per database (custom format, verified with `pg_restore --list`) + roles |
| Automation workflows | readable JSON export in addition to the database dump |
| Frigate database | SQLite online backup API (consistent while Frigate writes) + `integrity_check` |
| Configuration | application directory (excluding re-buildable model cache), selected system files |
| Face library | separate sub-archive (biometric, protected) |
| Inventory | OS, kernel, GPU driver, image digests, packages, disks, interfaces — enough to rebuild |
| Router configuration | weekly export over SSH by a read-only account, **without secrets** |
| **Not** backed up | ordinary recordings, previews, event snapshots, model cache |

Schedule and targets:

- **Daily** archive (~21 MB) to the **SSD and the video HDD**; the HDD copy
  is written only if the expected disk is really mounted (UUID check), so a
  missing disk can never turn the "second copy" into a second file on the
  same SSD. Both copies are byte-compared.
- **Encrypted off-site copy** (age, public key on the server; the private
  key exists only with the owner). Sent right after the backup and retried
  **every hour** until it succeeds, each file once — the bench's nightly
  internet block delays the copy to the morning instead of skipping a day.
  The receiver accepts uploads into a write-only drop box and moves them
  out of the uploader's reach, so a compromised site cannot delete received
  copies.
- **Monthly** manual copy to a USB stick, with the recovery procedures.
- Retention: 14 daily + 8 weekly locally; receiver keeps 30 days + 12
  monthly.

Alerts: a failed backup is reported immediately; a weekly summary reports
size, off-site, router export, restore test and SMART; a separate daily
check raises warning/high/critical at 20/26/48 hours since the last good
backup (the recovery-point objective is 24 hours). Disk SMART failures are
pushed to Telegram.

## 4. Restore testing

| Level | What | When |
| --- | --- | --- |
| 1 | checksums, `pg_restore --list`, SQLite integrity, SSD/HDD byte compare | every backup |
| 2 | restore both databases into temporary databases, run real queries (workflow count, daily report), drop | weekly, automatic |
| 3 | full rebuild on separate hardware from an off-site copy, isolated network | planned |

## 5. Findings worth keeping

- **A dump restored, but the application did not.** Functions depended on
  a role-level setting that is not part of a database dump — found only
  because the test ran a real report, not a row count. Fixed by pinning
  the search path on every function.
- **A "read-only" router account still exported Wi-Fi keys** on the older
  router OS version, which needs an explicit flag to hide secrets. The
  export command was changed per OS version, and any export that still
  contains a key or password field is discarded and reported.
- **A weekly restore test must not cancel the backup.** The first draft
  aborted the whole run when the test failed; the test now reports instead.

## 6. Failure procedures

One short procedure per failure, each with "when to open", "what you need",
numbered steps and an acceptance checklist: system SSD, video HDD, GPU
(same model / other NVIDIA / non-NVIDIA), mainboard or CPU (MAC address
change → DHCP reservation, firmware power settings, Secure Boot and the GPU
driver), router or AP replacement (re-import, new VPN key), camera
replacement, decrypting an off-site copy, Clonezilla system image, restore
test. A copy of the procedures travels with each monthly USB backup.

Estimated recovery times (not yet measured): HDD 1–3 h, SSD 3–8 h, whole
server — a working day plus hardware.
