from __future__ import annotations

import base64
import json

from common.events import extract_inventory_location, extract_run_id_from_inventory_key, parse_event_payload


def test_parse_event_payload_supports_base64_json():
    raw = json.dumps({"hello": "world"}).encode("utf-8")
    payload = base64.b64encode(raw).decode("utf-8")
    assert parse_event_payload(payload) == {"hello": "world"}


def test_extract_inventory_location_from_oss_event():
    event = {
        "events": [
            {
                "oss": {
                    "bucket": {"name": "bucket-a"},
                    "object": {"key": "ssl-check/inventory/run-1/domains.csv"},
                }
            }
        ]
    }

    assert extract_inventory_location(event) == ("bucket-a", "ssl-check/inventory/run-1/domains.csv")


def test_extract_run_id_from_inventory_key():
    assert extract_run_id_from_inventory_key("ssl-check/inventory/20260409/domains.csv") == "20260409"
    assert extract_run_id_from_inventory_key("ssl-check/ssl-report/20260409/report.csv") is None
