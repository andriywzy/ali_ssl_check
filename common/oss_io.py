from __future__ import annotations

import base64
import hashlib
import hmac
import json
from datetime import datetime, timezone
from typing import Any
from urllib.error import HTTPError
from urllib.parse import quote, urlsplit
from urllib.request import Request, urlopen

from common.config import AppConfig
from common.models import Credentials


def _normalize_endpoint(config: AppConfig) -> str:
    if config.oss_endpoint:
        endpoint = config.oss_endpoint.strip()
        if endpoint.startswith("http://") or endpoint.startswith("https://"):
            return endpoint
        return f"https://{endpoint}"

    if not config.oss_region:
        raise ValueError("OSS endpoint is ambiguous. Set OSS_ENDPOINT or OSS_REGION.")
    return f"https://oss-{config.oss_region}.aliyuncs.com"


class OSSStore:
    def __init__(self, config: AppConfig, credentials: Credentials):
        self._endpoint = _normalize_endpoint(config).rstrip("/")
        self._bucket = config.oss_bucket
        self._credentials = credentials

    def put_text(self, key: str, content: str, content_type: str) -> None:
        payload = content.encode("utf-8")
        self._request("PUT", key, payload, content_type)

    def put_json(self, key: str, payload: dict[str, Any]) -> None:
        self.put_text(
            key=key,
            content=json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True),
            content_type="application/json; charset=utf-8",
        )

    def get_text(self, key: str) -> str:
        return self._request("GET", key, None, "").decode("utf-8")

    def _request(self, method: str, key: str, payload: bytes | None, content_type: str) -> bytes:
        normalized_key = key.lstrip("/")
        url = _build_object_url(self._endpoint, self._bucket, normalized_key)
        date_header = _oss_http_date()
        headers = {
            "Date": date_header,
            "Content-Type": content_type,
        }
        if self._credentials.security_token:
            headers["x-oss-security-token"] = self._credentials.security_token
        if payload is not None:
            headers["Content-Length"] = str(len(payload))

        headers["Authorization"] = _build_authorization_header(
            method=method,
            bucket=self._bucket,
            key=normalized_key,
            access_key_id=self._credentials.access_key_id,
            access_key_secret=self._credentials.access_key_secret,
            date_header=date_header,
            content_type=content_type,
            security_token=self._credentials.security_token,
        )

        request = Request(url=url, data=payload, method=method)
        for header_name, header_value in headers.items():
            if header_value:
                request.add_header(header_name, header_value)

        try:
            with urlopen(request, timeout=30) as response:
                return response.read()
        except HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(
                f"OSS {method} failed with HTTP {exc.code} for {url}: {body}"
            ) from exc


def _build_authorization_header(
    method: str,
    bucket: str,
    key: str,
    access_key_id: str,
    access_key_secret: str,
    date_header: str,
    content_type: str,
    security_token: str | None,
) -> str:
    canonical_headers = []
    if security_token:
        canonical_headers.append(f"x-oss-security-token:{security_token}")
    canonicalized_oss_headers = ""
    if canonical_headers:
        canonicalized_oss_headers = "\n".join(sorted(canonical_headers)) + "\n"

    string_to_sign = "\n".join(
        [
            method,
            "",
            content_type or "",
            date_header,
            canonicalized_oss_headers + f"/{bucket}/{key}",
        ]
    )
    signature = base64.b64encode(
        hmac.new(
            access_key_secret.encode("utf-8"),
            string_to_sign.encode("utf-8"),
            hashlib.sha1,
        ).digest()
    ).decode("utf-8")
    return f"OSS {access_key_id}:{signature}"


def _oss_http_date() -> str:
    now = datetime.now(timezone.utc)
    return now.strftime("%a, %d %b %Y %H:%M:%S GMT")


def _build_object_url(endpoint: str, bucket: str, key: str) -> str:
    parsed = urlsplit(endpoint)
    if not parsed.scheme or not parsed.netloc:
        raise ValueError(f"Invalid OSS endpoint: {endpoint}")
    object_key = quote(key, safe="/")
    return f"{parsed.scheme}://{bucket}.{parsed.netloc}/{object_key}"
