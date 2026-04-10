from __future__ import annotations

from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class Credentials:
    access_key_id: str
    access_key_secret: str
    security_token: str | None = None
    region_id: str | None = None


@dataclass(frozen=True)
class InventoryRecord:
    run_id: str
    zone_domain: str
    rr: str
    fqdn: str
    record_type: str
    record_value: str
    ttl: int | str | None
    line: str
    dns_status: str
    resolved_values: str
    skip_reason: str
    collected_at: str

    def to_dict(self) -> dict[str, str | int | None]:
        return asdict(self)


@dataclass(frozen=True)
class SSLCheckResult:
    run_id: str
    fqdn: str
    port: int
    status: str
    days_remaining: int | str
    threshold_days: int
    not_after_utc: str
    issuer: str
    subject_cn: str
    san_count: int
    error_message: str
    checked_at: str

    def to_dict(self) -> dict[str, str | int]:
        return asdict(self)
