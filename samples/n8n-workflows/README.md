# n8n temperature workflow samples

These four JSON files are sanitized copies of bench workflow exports from
n8n 2.40.6. They let a reviewer inspect the actual node graph connecting
the [MQTT contract](../mqtt-contract/README.md) to the
[PostgreSQL functions](../telemetry-db/README.md). They are inactive,
contain no credential bindings, and are intended for inspection only.

The system was designed and built by the owner with AI-assisted engineering
tools (Claude, Codex, ChatGPT). The owner retained responsibility for
architecture, requirements, validation, and deployment decisions.

## What each workflow does

| Public file | Source workflow name | Role |
| --- | --- | --- |
| `temperature-ingest.json` | `Telemetry ingest` | Receives measurement, status, and availability topics; calls `telemetry.ingest_measurement` or `telemetry.ingest_node_message`; publishes the database ACK at QoS 1 when applicable. |
| `temperature-alarms.json` | `Telemetry alarms` | Calls `telemetry.evaluate_alarms`, reads unsent `notification_outbox` rows, sends Telegram notices to two recipient nodes, and marks rows sent. |
| `temperature-daily.json` | `Telemetry daily` | Calls `telemetry.daily_report` and sends its summary to Telegram. |
| `temperature-heartbeat.json` | `Telemetry heartbeat` | Queries telemetry health and posts a small summary to a synthetic watchdog endpoint. |

The JSON schedule definitions were preserved exactly. The two minute-based
workflows export only `field: minutes`: n8n omits parameters equal to the
node default, and the default *Minutes Between Triggers* is 5 — the 5-minute
cadence configured in the editor (owner-reported). The daily workflow runs
at 08:00 in the instance time zone.

## What “sanitized” means here, precisely

- All 13 credential bindings, including their IDs and display names, were
  removed. Credential-requiring nodes import as unconfigured.
- Three Telegram chat references became `REPLACE_WITH_CHAT_ID` or
  `REPLACE_WITH_SECOND_RECIPIENT_CHAT_ID`.
- Two recipient node names became `Send to owner` and
  `Send to second recipient`. Their connection keys and targets were
  updated to preserve the graph.
- The heartbeat destination became
  `https://watchdog.example.invalid/webhook/site-heartbeat`. The one
  site label in its SQL became `sample-site`; the query structure is
  unchanged.
- All 18 node IDs, three webhook IDs, four workflow IDs, and four version
  IDs were regenerated as unique UUIDs. The private instance marker was
  removed. Pin data and tags are empty. All workflows changed from active
  to inactive.
- No node was added or removed. SQL logic, schedules, QoS, options, and
  connection structure were preserved. Other parameters and expressions
  are byte-for-byte equal after the listed substitutions.

### Node ID remapping

| Workflow | Nodes | Node IDs regenerated | Webhook IDs regenerated |
| --- | ---: | ---: | ---: |
| Temperature ingestion and acknowledgement | 6 | 6 | 0 |
| Temperature alarm notifications | 6 | 6 | 2 |
| Daily temperature summary | 3 | 3 | 1 |
| Watchdog heartbeat | 3 | 3 | 0 |

The four workflow IDs and four version IDs were regenerated as well.

[`verify_structure.py`](verify_structure.py) compares these files with the
four source exports supplied separately. It checks the full node and
parameter objects, remapped connections, UUID uniqueness, and the exact
allowlist of differences. It prints counts and categories, never source
values. With authorized access to the exports, run:

```sh
python verify_structure.py <source-export-directory>
```

The final public files were also scanned for long digit runs, IPv4 forms,
email separators, plain HTTP URLs, and known private names. No matches
remained in the four workflow JSON files.

## Import verification

All four files were imported together into a disposable n8n 2.40.6
container with no network access and a fresh in-memory user folder. A
subsequent export from that same container confirmed four inactive
workflows, 18 nodes, and no credential bindings. The container used `--rm`;
its temporary data disappeared when it exited. The included
[`verify_import.sh`](verify_import.sh) is the container-side check; it
imports into the n8n instance in which it runs, so use it only in a
disposable instance.

## What this is not

Import proves that n8n accepts these JSON definitions. It does not execute
the workflows, connect to a broker, database, Telegram, or watchdog, or
prove that this snapshot is identical to the currently running bench
configuration. The underlying platform is bench-tested, installation is
in progress, and production behavior is unverified.
