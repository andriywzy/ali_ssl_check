from __future__ import annotations

import os
from dataclasses import dataclass


def _get_int_env(name: str, default: int) -> int:
    value = os.getenv(name)
    if value is None or value == "":
        return default
    return int(value)


def _normalize_prefix(prefix: str) -> str:
    prefix = prefix.strip().strip("/")
    return prefix


def _get_key_env(name: str) -> str | None:
    value = os.getenv(name)
    if value is None:
        return None
    value = value.strip().strip("/")
    return value or None


@dataclass(frozen=True)
class AppConfig:
    oss_bucket: str
    oss_prefix: str
    inventory_csv_object_key: str
    inventory_summary_object_key: str
    ssl_report_csv_object_key: str
    ssl_report_summary_object_key: str
    expiry_threshold_days: int
    ssl_port: int
    dns_timeout_sec: int
    tls_timeout_sec: int
    check_concurrency: int
    oss_endpoint: str | None
    oss_region: str | None
    alidns_region_id: str

    @classmethod
    def from_env(cls) -> "AppConfig":
        bucket = os.getenv("OSS_BUCKET", "").strip()
        if not bucket:
            raise ValueError("OSS_BUCKET is required")

        prefix = _normalize_prefix(os.getenv("OSS_PREFIX", "ssl-check"))
        oss_endpoint = os.getenv("OSS_ENDPOINT")
        oss_region = os.getenv("OSS_REGION") or os.getenv("ALIBABA_CLOUD_REGION_ID") or os.getenv("FC_REGION")
        alidns_region_id = os.getenv("ALIDNS_REGION_ID") or os.getenv("ALIBABA_CLOUD_REGION_ID") or "cn-hangzhou"

        inventory_csv_key = _get_key_env("INVENTORY_CSV_OBJECT_KEY")
        inventory_summary_key = _get_key_env("INVENTORY_SUMMARY_OBJECT_KEY")
        ssl_report_csv_key = _get_key_env("SSL_REPORT_CSV_OBJECT_KEY")
        ssl_report_summary_key = _get_key_env("SSL_REPORT_SUMMARY_OBJECT_KEY")

        return cls(
            oss_bucket=bucket,
            oss_prefix=prefix,
            inventory_csv_object_key=inventory_csv_key or cls._default_object_key(prefix, "inventory", "domains.csv"),
            inventory_summary_object_key=inventory_summary_key or cls._default_object_key(prefix, "inventory", "summary.json"),
            ssl_report_csv_object_key=ssl_report_csv_key or cls._default_object_key(prefix, "ssl-report", "ssl_report.csv"),
            ssl_report_summary_object_key=ssl_report_summary_key or cls._default_object_key(prefix, "ssl-report", "summary.json"),
            expiry_threshold_days=_get_int_env("EXPIRY_THRESHOLD_DAYS", 10),
            ssl_port=_get_int_env("SSL_PORT", 443),
            dns_timeout_sec=_get_int_env("DNS_TIMEOUT_SEC", 5),
            tls_timeout_sec=_get_int_env("TLS_TIMEOUT_SEC", 8),
            check_concurrency=_get_int_env("CHECK_CONCURRENCY", 20),
            oss_endpoint=oss_endpoint.strip() if oss_endpoint else None,
            oss_region=oss_region.strip() if oss_region else None,
            alidns_region_id=alidns_region_id,
        )

    def object_key(self, *parts: str) -> str:
        clean_parts = [part.strip("/") for part in parts if part and part.strip("/")]
        if self.oss_prefix:
            clean_parts.insert(0, self.oss_prefix)
        return "/".join(clean_parts)

    @staticmethod
    def _default_object_key(prefix: str, *parts: str) -> str:
        clean_parts = [part.strip("/") for part in parts if part and part.strip("/")]
        if prefix:
            clean_parts.insert(0, prefix)
        return "/".join(clean_parts)

    def inventory_csv_key(self) -> str:
        return self.inventory_csv_object_key

    def inventory_summary_key(self) -> str:
        return self.inventory_summary_object_key

    def ssl_report_csv_key(self) -> str:
        return self.ssl_report_csv_object_key

    def ssl_report_summary_key(self) -> str:
        return self.ssl_report_summary_object_key
