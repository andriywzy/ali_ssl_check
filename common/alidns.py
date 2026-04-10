from __future__ import annotations

import base64
import hashlib
import hmac
import json
from dataclasses import dataclass
from typing import Any
from urllib.error import HTTPError
from urllib.parse import quote, urlencode
from urllib.request import urlopen
from uuid import uuid4

from common.config import AppConfig
from common.models import Credentials
from common.time_utils import utc_now


ALIDNS_ENDPOINT = "https://alidns.cn-hangzhou.aliyuncs.com/"
ALIDNS_VERSION = "2015-01-09"


@dataclass(frozen=True)
class ManagedDomain:
    domain_name: str
    record_count: int


@dataclass(frozen=True)
class ParsedDomainRecord:
    type: str
    rr: str
    value: str
    ttl: int | None
    line: str
    status: str


@dataclass(frozen=True)
class AlidnsClient:
    access_key_id: str
    access_key_secret: str
    security_token: str | None = None

    def call(self, action: str, **params: Any) -> dict[str, Any]:
        common_params = {
            "AccessKeyId": self.access_key_id,
            "Action": action,
            "Format": "JSON",
            "SignatureMethod": "HMAC-SHA1",
            "SignatureNonce": uuid4().hex,
            "SignatureVersion": "1.0",
            "Timestamp": utc_now().replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            "Version": ALIDNS_VERSION,
        }
        if self.security_token:
            common_params["SecurityToken"] = self.security_token

        all_params = {**common_params, **{key: str(value) for key, value in params.items() if value is not None}}
        all_params["Signature"] = _build_signature(all_params, self.access_key_secret)
        url = f"{ALIDNS_ENDPOINT}?{urlencode(all_params)}"

        try:
            with urlopen(url, timeout=30) as response:
                return json.loads(response.read().decode("utf-8"))
        except HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"AliDNS API {action} failed with HTTP {exc.code}: {body}") from exc


def build_alidns_client(config: AppConfig, credentials: Credentials) -> AlidnsClient:
    del config
    return AlidnsClient(
        access_key_id=credentials.access_key_id,
        access_key_secret=credentials.access_key_secret,
        security_token=credentials.security_token,
    )


def list_managed_domains(client: AlidnsClient) -> list[ManagedDomain]:
    page_number = 1
    page_size = 100
    results: list[ManagedDomain] = []

    while True:
        payload = client.call("DescribeDomains", PageNumber=page_number, PageSize=page_size)
        current = payload.get("Domains", {}).get("Domain", []) or []
        for domain in current:
            results.append(
                ManagedDomain(
                    domain_name=domain.get("DomainName", ""),
                    record_count=int(domain.get("RecordCount", 0) or 0),
                )
            )
        total_count = int(payload.get("TotalCount", len(results)) or len(results))
        if not current or len(results) >= total_count:
            break
        page_number += 1

    return results


def list_domain_records(client: AlidnsClient, zone_domain: str) -> list[ParsedDomainRecord]:
    page_number = 1
    page_size = 500
    results: list[ParsedDomainRecord] = []

    while True:
        payload = client.call(
            "DescribeDomainRecords",
            DomainName=zone_domain,
            PageNumber=page_number,
            PageSize=page_size,
        )
        current = payload.get("DomainRecords", {}).get("Record", []) or []
        for record in current:
            results.append(
                ParsedDomainRecord(
                    type=(record.get("Type") or ""),
                    rr=(record.get("RR") or ""),
                    value=(record.get("Value") or ""),
                    ttl=int(record["TTL"]) if record.get("TTL") not in (None, "") else None,
                    line=(record.get("Line") or ""),
                    status=(record.get("Status") or ""),
                )
            )
        total_count = int(payload.get("TotalCount", len(results)) or len(results))
        if not current or len(results) >= total_count:
            break
        page_number += 1

    return results


def get_authoritative_nameservers(client: AlidnsClient, zone_domain: str) -> list[str]:
    payload = client.call("DescribeDomainNs", DomainName=zone_domain)
    return list(payload.get("DnsServers", {}).get("DnsServer", []) or [])


def _build_signature(params: dict[str, str], access_key_secret: str) -> str:
    canonicalized = "&".join(
        f"{_percent_encode(key)}={_percent_encode(value)}"
        for key, value in sorted(params.items(), key=lambda item: item[0])
        if value is not None
    )
    string_to_sign = f"GET&%2F&{_percent_encode(canonicalized)}"
    digest = hmac.new(
        f"{access_key_secret}&".encode("utf-8"),
        string_to_sign.encode("utf-8"),
        hashlib.sha1,
    ).digest()
    return base64.b64encode(digest).decode("utf-8")


def _percent_encode(value: Any) -> str:
    encoded = quote(str(value), safe="~")
    return encoded.replace("+", "%20").replace("*", "%2A").replace("%7E", "~")
