# Backup and recovery tooling sample

This sanitized operations sample demonstrates a daily logical backup pipeline. It is a review artifact, not a ready-to-run deployment: site paths, receiver account, age recipient, router addresses, and mounted disk UUID must be supplied and verified for a real installation. No keys, passwords, tokens, private inventory, video, or backup archives are included.

The system was designed and built by the owner with AI-assisted engineering tools (Claude, Codex, ChatGPT). The owner retained architecture, requirements, validation, and deployment decisions.

## Design

- The daily job runs per-database PostgreSQL `pg_dump`, PostgreSQL globals, an n8n workflow export, SQLite online backups, selected configuration and face library files, and a technical inventory. Ordinary video recordings are excluded. A manifest and SHA-256 list accompany the archive.
- It checks the HDD mountpoint and expected UUID before writing there. It writes an SSD archive, verifies it, copies and compares it to the HDD, and advances the success marker only after both local copies succeed. An incomplete pair fails the job.
- An age-encrypted copy is staged in a restricted outbox. The sender retries hourly and uses per-file `.sent` markers so an already delivered archive is not regenerated or resent. Large archives are deferred to the monthly window. The receiver should provide append-only access to a restricted account; receiver implementation and any private routing are deliberately omitted.
- Weekly router exports use `hide-sensitive` with RouterOS 6. A read-only RouterOS 6 export can still expose Wi-Fi keys without it. The script rejects export text containing secret-field names before retaining it. The weekly job also restores database dumps into new databases and calls a telemetry report function. Router exports omit secret material and are not a complete router disaster-recovery image.
- Independent age monitoring warns after 20 hours, escalates at 26 and 48 hours, and the off-site sender alerts after a prolonged pending copy. Weekly SMART health checks are included. The manual restore helper verifies checksums, dump TOCs, and SQLite integrity before extraction; live database restoration requires an empty destination and typed confirmation.
- Optional daily CSV and monthly telemetry-file jobs, a bot polling script, timers, and a laptop pull example show the surrounding operational flow. The laptop pull checks the downloaded encrypted file's SHA-256 digest.

## Review and syntax check

```sh
find . -name '*.sh' -print0 | xargs -0 -n1 bash -n
```

If installed, `shellcheck` can be run over the same list. These checks only prove shell syntax; none of the scripts are executed against equipment by this sample. The PostgreSQL restore behavior is independently exercised by the `telemetry-db` test container.

## Sanitization log and evidence

| Source category | Public treatment |
| --- | --- |
| Server application path | Generic `/opt/ivp` |
| Router management addresses | `<router-a-address>` and `<router-b-address>` placeholders |
| Router/off-site account names, address, and path | Synthetic account names, empty fields, or generic path examples; no live value |
| Private decision/evidence references and site-specific comments | Removed or rewritten as engineering descriptions |
| Notifications | Keep operator-facing Russian text; no token or chat ID value |

The source scripts were sanitized for disclosure, with operational branches retained. This sample has no end-to-end backup run. The private bench has an owner-reported initial encrypted backup and laptop decrypt check; the off-site receiver is configured and has received copies (owner-reported); a full restore rehearsal on separate hardware remains open. Installation is in progress and production recovery is unverified.
