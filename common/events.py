from __future__ import annotations

import base64
import json
from typing import Any
from urllib.parse import unquote_plus


def parse_event_payload(event: Any) -> Any:
    if event is None:
        return {}
    if isinstance(event, (dict, list)):
        return event
    if hasattr(event, "read"):
        raw = event.read()
    else:
        raw = event

    if isinstance(raw, bytes):
        text = raw.decode("utf-8").strip()
    else:
        text = str(raw).strip()

    if not text:
        return {}

    for candidate in (text, _try_base64_decode(text)):
        if not candidate:
            continue
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            continue

    raise ValueError("Unable to parse event payload as JSON.")


def extract_inventory_location(payload: Any) -> tuple[str | None, str | None]:
    data = parse_event_payload(payload)
    if isinstance(data, dict):
        if data.get("inventory_key") or data.get("key"):
            return data.get("bucket"), data.get("inventory_key") or data.get("key")
        if isinstance(data.get("data"), dict):
            bucket, key = extract_inventory_location(data["data"])
            if key:
                return bucket, key
        events = data.get("events")
        if isinstance(events, list):
            for event_item in events:
                bucket, key = _extract_oss_event(event_item)
                if key:
                    return bucket, key
        bucket, key = _extract_oss_event(data)
        if key:
            return bucket, key
    return None, None


def _extract_oss_event(payload: dict[str, Any]) -> tuple[str | None, str | None]:
    oss_section = payload.get("oss") if isinstance(payload, dict) else None
    if not isinstance(oss_section, dict):
        return None, None
    bucket = None
    key = None
    if isinstance(oss_section.get("bucket"), dict):
        bucket = oss_section["bucket"].get("name")
    if isinstance(oss_section.get("object"), dict):
        key = oss_section["object"].get("key")
    if key:
        key = unquote_plus(key)
    return bucket, key


def extract_run_id_from_inventory_key(key: str | None) -> str | None:
    if not key:
        return None
    parts = [part for part in key.split("/") if part]
    if len(parts) < 3:
        return None
    if parts[-1] != "domains.csv":
        return None
    return parts[-2]


def _try_base64_decode(text: str) -> str | None:
    try:
        decoded = base64.b64decode(text, validate=True)
    except Exception:
        return None
    try:
        return decoded.decode("utf-8").strip()
    except UnicodeDecodeError:
        return None
