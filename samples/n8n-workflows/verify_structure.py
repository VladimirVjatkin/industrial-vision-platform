#!/usr/bin/env python3
"""Compare private exports with public copies without printing private values."""
import argparse
from copy import deepcopy
import json
from pathlib import Path
import re
import uuid

FILES = {
    "Telemetry ingest.json": ("temperature-ingest.json", "Temperature ingestion and acknowledgement"),
    "Telemetry alarms.json": ("temperature-alarms.json", "Temperature alarm notifications"),
    "Telemetry daily.json": ("temperature-daily.json", "Daily temperature summary"),
    "Telemetry heartbeat.json": ("temperature-heartbeat.json", "Watchdog heartbeat"),
}


def load(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def valid_new_id(new, old, seen):
    assert isinstance(new, str) and new != old
    assert uuid.UUID(new).version == 4
    assert new not in seen
    seen.add(new)


def remap_connections(value, names):
    if isinstance(value, dict):
        return {key: names.get(item, item) if key == "node" and isinstance(item, str)
                else remap_connections(item, names) for key, item in value.items()}
    if isinstance(value, list):
        return [remap_connections(item, names) for item in value]
    return value


def verify(source_dir, public_dir):
    totals = dict(nodes=0, edges=0, credentials=0, node_ids=0, webhook_ids=0,
                  chat_ids=0, urls=0, site_literals=0, renamed_nodes=0)
    seen_ids = set()
    for src_name, (pub_name, expected_name) in FILES.items():
        source = load(source_dir / src_name)
        public = load(public_dir / pub_name)
        assert source["name"] == src_name[:-5], "Unexpected source workflow name"
        assert public["name"] == expected_name
        assert source["active"] is True and public["active"] is False
        assert "instanceId" in source.get("meta", {})
        assert "instanceId" not in public.get("meta", {})
        assert public.get("pinData") == {}
        assert len(source["nodes"]) == len(public["nodes"])
        valid_new_id(public["id"], source["id"], seen_ids)
        valid_new_id(public["versionId"], source["versionId"], seen_ids)
        names = {}
        for index, (old, new) in enumerate(zip(source["nodes"], public["nodes"])):
            totals["nodes"] += 1
            valid_new_id(new["id"], old["id"], seen_ids)
            totals["node_ids"] += 1
            if "webhookId" in old:
                valid_new_id(new["webhookId"], old["webhookId"], seen_ids)
                totals["webhook_ids"] += 1
            else:
                assert "webhookId" not in new
            assert "credentials" not in new
            if "credentials" in old:
                totals["credentials"] += 1
            if src_name == "Telemetry alarms.json" and index in (4, 5):
                expected_node_name = "Send to owner" if index == 4 else "Send to second recipient"
                assert new["name"] == expected_node_name
                names[old["name"]] = expected_node_name
                totals["renamed_nodes"] += 1
            else:
                assert new["name"] == old["name"]
            a, b = deepcopy(old), deepcopy(new)
            for key in ("id", "webhookId", "credentials", "name"):
                a.pop(key, None)
                b.pop(key, None)
            if old["type"].endswith(".telegram"):
                expected_chat = ("REPLACE_WITH_SECOND_RECIPIENT_CHAT_ID"
                                 if src_name == "Telemetry alarms.json" and index == 5
                                 else "REPLACE_WITH_CHAT_ID")
                assert b["parameters"]["chatId"] == expected_chat
                assert a["parameters"]["chatId"] != expected_chat
                b["parameters"]["chatId"] = a["parameters"]["chatId"]
                totals["chat_ids"] += 1
            if old["type"].endswith(".httpRequest"):
                assert src_name == "Telemetry heartbeat.json"
                assert b["parameters"]["url"] == "https://watchdog.example.invalid/webhook/site-heartbeat"
                assert b["parameters"]["url"] != a["parameters"]["url"]
                b["parameters"]["url"] = a["parameters"]["url"]
                totals["urls"] += 1
            if src_name == "Telemetry heartbeat.json" and old["type"].endswith(".postgres"):
                original_sql = a["parameters"]["query"]
                generic_sql = re.sub(r"(?<=SELECT ')[^']+(?=' AS site,)",
                                     "sample-site", original_sql, count=1)
                assert generic_sql != original_sql
                assert b["parameters"]["query"] == generic_sql
                b["parameters"]["query"] = original_sql
                totals["site_literals"] += 1
            assert a == b, f"Unapproved node/parameter change in {pub_name}, node {index}"
        expected_connections = {names.get(key, key): remap_connections(value, names)
                                for key, value in source["connections"].items()}
        assert public["connections"] == expected_connections, f"Connection change in {pub_name}"
        node_names = {node["name"] for node in public["nodes"]}
        assert len(node_names) == len(public["nodes"])
        for wires in public["connections"].values():
            def check_edges(value):
                if isinstance(value, dict):
                    if "node" in value:
                        assert value["node"] in node_names
                        totals["edges"] += 1
                    for child in value.values(): check_edges(child)
                elif isinstance(value, list):
                    for child in value: check_edges(child)
            check_edges(wires)
        a, b = deepcopy(source), deepcopy(public)
        for key in ("id", "versionId", "name", "active", "nodes", "connections"):
            a[key] = b[key]
        a.get("meta", {}).pop("instanceId", None)
        assert a == b, f"Unapproved workflow-level change in {pub_name}"
        print(f"PASS {pub_name}: {len(public['nodes'])} nodes; connections and all other parameters unchanged")
    print("PASS allowed changes:", ", ".join(f"{key}={value}" for key, value in totals.items()))
    print("PASS SQL structure, schedules, QoS, options and graph unchanged; one site literal sanitized")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source_dir", type=Path, help="Directory containing the four private exports")
    parser.add_argument("--public-dir", type=Path, default=Path(__file__).parent)
    args = parser.parse_args()
    verify(args.source_dir, args.public_dir)
