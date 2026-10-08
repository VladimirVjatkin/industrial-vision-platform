#!/usr/bin/env python3
"""Validate the public synthetic MQTT examples without dependencies."""
import json
import math
import re
import uuid
from pathlib import Path

ROOT = Path(__file__).parent / "examples"
NODE = re.compile(r"[a-z0-9-]{3,32}\Z")
ROM = re.compile(r"[0-9A-F]{16}\Z")


def integer(value):
    return type(value) is int and value >= 0


def common(payload):
    assert type(payload.get("schema_version")) is int and payload["schema_version"] == 1
    assert uuid.UUID(payload["boot_id"]).version == 4


def validate(kind, payload):
    common(payload)
    if kind != "ack":
        assert NODE.fullmatch(payload["node_id"])
    if kind != "status":
        assert ROM.fullmatch(payload["sensor_id"])
        assert integer(payload["seq"])
    if kind == "measurement":
        assert integer(payload["uptime_ms"])
        assert payload["unit"] == "C"
        assert payload["quality"] in {"ok", "not_found", "crc_error", "conversion_timeout", "suspect"}
        assert payload["time_quality"] in {"synced", "estimated", "unsynced"}
        assert type(payload["buffered"]) is bool
        assert isinstance(payload["firmware_version"], str)
        value = payload["value"]
        assert value is None or (type(value) in (int, float) and math.isfinite(value) and -55 <= value <= 125)
        assert (value is not None) == (payload["quality"] in ("ok", "suspect")) or (value is None and payload["quality"] == "suspect")
        assert payload["measured_at"] is None or re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", payload["measured_at"])
    elif kind == "status":
        assert integer(payload["uptime_ms"])
        assert payload["time_quality"] in {"synced", "estimated", "unsynced"}
        assert type(payload["wifi_rssi"]) is int
        assert all(integer(payload[key]) for key in ("sensors_found", "buffer_depth", "buffer_dropped"))
        assert isinstance(payload["firmware_version"], str)
    elif kind == "ack":
        assert payload["result"] in {"stored", "duplicate", "rejected"}


for path in sorted(ROOT.glob("*.json")):
    validate(path.stem, json.loads(path.read_text(encoding="utf-8")))
    print(f"PASS: {path.name}")
