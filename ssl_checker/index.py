from __future__ import annotations

import json
import logging
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import replace
from typing import Any

from common.config import AppConfig
from common.credentials import load_credentials
from common.csv_io import dump_csv, load_csv
from common.events import extract_run_id_from_inventory_key
from common.models import SSLCheckResult
from common.oss_io import OSSStore
from common.ssl_checks import check_certificate
from common.time_utils import generate_run_id


LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

SSL_FIELDNAMES = [
    "run_id",
    "fqdn",
    "port",
    "status",
    "days_remaining",
    "threshold_days",
    "not_after_utc",
    "issuer",
    "subject_cn",
    "san_count",
    "error_message",
    "checked_at",
]


def handler(event: Any, context: Any) -> dict[str, Any]:
    del event
    config = AppConfig.from_env()
    credentials = load_credentials(context)
    oss_store = OSSStore(config, credentials)

    inventory_key = config.inventory_csv_key()
    inventory_rows = load_csv(oss_store.get_text(inventory_key))
    run_id = _resolve_run_id(inventory_key, inventory_rows)
    results = check_inventory_rows(inventory_rows, run_id, config)

    ssl_csv_key = config.ssl_report_csv_key()
    ssl_summary_key = config.ssl_report_summary_key()
    summary = build_summary(config, run_id, inventory_key, ssl_csv_key, ssl_summary_key, results, len(inventory_rows))

    oss_store.put_text(
        ssl_csv_key,
        dump_csv((_report_row(result).to_dict() for result in results), SSL_FIELDNAMES),
        "text/csv; charset=utf-8",
    )
    oss_store.put_json(ssl_summary_key, summary)

    LOGGER.info("ssl report generated run_id=%s checks=%s", run_id, len(results))
    return summary


def check_inventory_rows(rows: list[dict[str, str]], run_id: str, config: AppConfig) -> list[SSLCheckResult]:
    fqdn_candidates = sorted(
        {
            row["fqdn"].strip()
            for row in rows
            if row.get("fqdn")
            and row.get("dns_status") == "resolved"
            and not row.get("skip_reason")
        }
    )

    results: list[SSLCheckResult] = []
    if not fqdn_candidates:
        return results

    with ThreadPoolExecutor(max_workers=max(1, config.check_concurrency)) as executor:
        future_map = {
            executor.submit(
                check_certificate,
                fqdn,
                config.ssl_port,
                config.expiry_threshold_days,
                config.tls_timeout_sec,
                run_id,
            ): fqdn
            for fqdn in fqdn_candidates
        }
        for future in as_completed(future_map):
            result = future.result()
            _log_threshold_breach(result)
            results.append(result)

    results.sort(key=lambda item: item.fqdn)
    return results


def build_summary(
    config: AppConfig,
    run_id: str,
    inventory_key: str,
    ssl_csv_key: str,
    ssl_summary_key: str,
    results: list[SSLCheckResult],
    source_row_count: int,
) -> dict[str, Any]:
    status_counter = Counter(result.status for result in results)
    return {
        "run_id": run_id,
        "oss_bucket": config.oss_bucket,
        "inventory_key": inventory_key,
        "ssl_report_csv_key": ssl_csv_key,
        "ssl_report_summary_key": ssl_summary_key,
        "source_row_count": source_row_count,
        "checked_fqdn_count": len(results),
        "threshold_days": config.expiry_threshold_days,
        "status_counts": dict(status_counter),
    }


def _resolve_run_id(inventory_key: str, rows: list[dict[str, str]]) -> str:
    for row in rows:
        run_id = (row.get("run_id") or "").strip()
        if run_id:
            return run_id
    return extract_run_id_from_inventory_key(inventory_key) or generate_run_id()


def _report_row(result: SSLCheckResult) -> SSLCheckResult:
    if result.status == "ok":
        return result
    return replace(result, days_remaining="")


def _log_threshold_breach(result: SSLCheckResult) -> None:
    if result.status != "expiring":
        return
    LOGGER.warning(
        json.dumps(
            {
                "event": "certificate_below_threshold",
                "fqdn": result.fqdn,
                "status": result.status,
                "days_remaining": result.days_remaining,
                "threshold_days": result.threshold_days,
                "not_after_utc": result.not_after_utc,
                "run_id": result.run_id,
                "port": result.port,
            },
            ensure_ascii=False,
            sort_keys=True,
        )
    )
