from __future__ import annotations

import logging
from collections import Counter
from typing import Any

from common.alidns import build_alidns_client, get_authoritative_nameservers, list_domain_records, list_managed_domains
from common.config import AppConfig
from common.credentials import load_credentials
from common.csv_io import dump_csv
from common.dns_checks import SUPPORTED_RECORD_TYPES, build_fqdn, resolve_authoritatively
from common.models import InventoryRecord
from common.oss_io import OSSStore
from common.time_utils import generate_run_id, utc_now_iso


LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

INVENTORY_FIELDNAMES = [
    "run_id",
    "zone_domain",
    "rr",
    "fqdn",
    "record_type",
    "record_value",
    "ttl",
    "line",
    "dns_status",
    "resolved_values",
    "skip_reason",
    "collected_at",
]


def handler(event: Any, context: Any) -> dict[str, Any]:
    del event
    config = AppConfig.from_env()
    credentials = load_credentials(context)
    run_id = generate_run_id()
    collected_at = utc_now_iso()

    alidns_client = build_alidns_client(config, credentials)
    oss_store = OSSStore(config, credentials)

    records = collect_inventory(alidns_client, run_id, collected_at, config)
    csv_payload = dump_csv((record.to_dict() for record in records), INVENTORY_FIELDNAMES)

    inventory_csv_key = config.inventory_csv_key()
    inventory_summary_key = config.inventory_summary_key()
    summary = build_summary(config, run_id, records, inventory_csv_key, inventory_summary_key)

    oss_store.put_text(inventory_csv_key, csv_payload, "text/csv; charset=utf-8")
    oss_store.put_json(inventory_summary_key, summary)

    LOGGER.info("inventory generated run_id=%s records=%s", run_id, len(records))
    return summary


def collect_inventory(alidns_client: Any, run_id: str, collected_at: str, config: AppConfig) -> list[InventoryRecord]:
    inventory_rows: list[InventoryRecord] = []
    domains = list_managed_domains(alidns_client)

    for domain in domains:
        zone_domain = getattr(domain, "domain_name", "")
        if not zone_domain:
            continue
        record_count = getattr(domain, "record_count", 0) or 0
        if record_count == 0:
            LOGGER.info("skip zone with zero records: %s", zone_domain)
            continue

        nameservers = get_authoritative_nameservers(alidns_client, zone_domain)
        records = list_domain_records(alidns_client, zone_domain)
        for record in records:
            record_status = (getattr(record, "status", "") or "").strip()
            if record_status.lower() == "disable":
                LOGGER.info(
                    "skip paused or disabled record zone=%s rr=%s type=%s status=%s",
                    zone_domain,
                    getattr(record, "rr", "") or "",
                    getattr(record, "type", "") or "",
                    record_status,
                )
                continue

            record_type = (getattr(record, "type", "") or "").upper()
            if record_type not in SUPPORTED_RECORD_TYPES:
                continue

            rr = getattr(record, "rr", "") or ""
            fqdn = build_fqdn(rr, zone_domain)
            skip_reason = ""
            dns_status = "unresolved"
            resolved_values: list[str] = []

            if rr == "*":
                skip_reason = "wildcard_record"
                dns_status = "skipped"
            else:
                dns_status, resolved_values = resolve_authoritatively(
                    fqdn=fqdn,
                    record_type=record_type,
                    nameservers=nameservers,
                    timeout_sec=config.dns_timeout_sec,
                )

            inventory_rows.append(
                InventoryRecord(
                    run_id=run_id,
                    zone_domain=zone_domain,
                    rr=rr,
                    fqdn=fqdn,
                    record_type=record_type,
                    record_value=str(getattr(record, "value", "") or ""),
                    ttl=getattr(record, "ttl", ""),
                    line=str(getattr(record, "line", "") or ""),
                    dns_status=dns_status,
                    resolved_values=";".join(resolved_values),
                    skip_reason=skip_reason,
                    collected_at=collected_at,
                )
            )

    return inventory_rows


def build_summary(
    config: AppConfig,
    run_id: str,
    records: list[InventoryRecord],
    inventory_csv_key: str,
    inventory_summary_key: str,
) -> dict[str, Any]:
    dns_status_counter = Counter(record.dns_status for record in records)
    skip_counter = Counter(record.skip_reason for record in records if record.skip_reason)
    candidate_count = sum(1 for record in records if record.dns_status == "resolved" and not record.skip_reason)

    return {
        "run_id": run_id,
        "oss_bucket": config.oss_bucket,
        "inventory_csv_key": inventory_csv_key,
        "inventory_summary_key": inventory_summary_key,
        "total_rows": len(records),
        "candidate_rows": candidate_count,
        "dns_status_counts": dict(dns_status_counter),
        "skip_reason_counts": dict(skip_counter),
    }
