from __future__ import annotations

import os
import socket
import ssl
import tempfile
from datetime import datetime, timezone
from typing import Any

from common.models import SSLCheckResult
from common.time_utils import utc_now, utc_now_iso


def check_certificate(
    fqdn: str,
    port: int,
    threshold_days: int,
    timeout_sec: int,
    run_id: str,
) -> SSLCheckResult:
    checked_at = utc_now_iso()

    try:
        cert = _fetch_leaf_certificate(fqdn, port, timeout_sec)
    except Exception as exc:
        return SSLCheckResult(
            run_id=run_id,
            fqdn=fqdn,
            port=port,
            status="error",
            days_remaining="",
            threshold_days=threshold_days,
            not_after_utc="",
            issuer="",
            subject_cn="",
            san_count=0,
            error_message=str(exc),
            checked_at=checked_at,
        )

    not_after = _parse_not_after(cert)
    issuer = _flatten_name(cert.get("issuer", ()))
    subject_cn = _extract_common_name(cert.get("subject", ()))
    san_count = len(cert.get("subjectAltName", ()))

    try:
        _verify_certificate(fqdn, port, timeout_sec)
    except Exception as exc:
        return SSLCheckResult(
            run_id=run_id,
            fqdn=fqdn,
            port=port,
            status="error",
            days_remaining=_days_remaining(not_after),
            threshold_days=threshold_days,
            not_after_utc=not_after.isoformat().replace("+00:00", "Z"),
            issuer=issuer,
            subject_cn=subject_cn,
            san_count=san_count,
            error_message=str(exc),
            checked_at=checked_at,
        )

    days_remaining = _days_remaining(not_after)
    if days_remaining < 0:
        status = "expired"
    elif days_remaining <= threshold_days:
        status = "expiring"
    else:
        status = "ok"

    return SSLCheckResult(
        run_id=run_id,
        fqdn=fqdn,
        port=port,
        status=status,
        days_remaining=days_remaining,
        threshold_days=threshold_days,
        not_after_utc=not_after.isoformat().replace("+00:00", "Z"),
        issuer=issuer,
        subject_cn=subject_cn,
        san_count=san_count,
        error_message="",
        checked_at=checked_at,
    )


def _fetch_leaf_certificate(fqdn: str, port: int, timeout_sec: int) -> dict[str, Any]:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE

    with socket.create_connection((fqdn, port), timeout=timeout_sec) as sock:
        with context.wrap_socket(sock, server_hostname=fqdn) as tls_sock:
            der_certificate = tls_sock.getpeercert(binary_form=True)
            if der_certificate:
                return _decode_der_certificate(der_certificate)

            certificate = tls_sock.getpeercert()
            if certificate:
                return certificate

            raise RuntimeError("Peer did not return a certificate.")


def _verify_certificate(fqdn: str, port: int, timeout_sec: int) -> None:
    context = ssl.create_default_context()
    with socket.create_connection((fqdn, port), timeout=timeout_sec) as sock:
        with context.wrap_socket(sock, server_hostname=fqdn):
            return None


def _parse_not_after(cert: dict[str, Any]) -> datetime:
    raw = cert.get("notAfter")
    if not raw:
        raise RuntimeError("Certificate is missing notAfter.")
    return datetime.strptime(raw, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)


def _extract_common_name(parts: Any) -> str:
    for rdn in parts:
        for key, value in rdn:
            if key == "commonName":
                return value
    return ""


def _flatten_name(parts: Any) -> str:
    flat_parts: list[str] = []
    for rdn in parts:
        for key, value in rdn:
            flat_parts.append(f"{key}={value}")
    return ", ".join(flat_parts)


def _days_remaining(not_after: datetime) -> int:
    remaining = not_after - utc_now()
    return int(remaining.total_seconds() // 86400)


def _decode_der_certificate(der_certificate: bytes) -> dict[str, Any]:
    decoder = getattr(getattr(ssl, "_ssl", None), "_test_decode_cert", None)
    if decoder is None:
        raise RuntimeError("Python runtime does not support certificate decoding.")

    pem_certificate = ssl.DER_cert_to_PEM_cert(der_certificate)
    certificate_path = ""
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as temp_file:
            temp_file.write(pem_certificate)
            certificate_path = temp_file.name
        return decoder(certificate_path)
    finally:
        if certificate_path:
            try:
                os.remove(certificate_path)
            except FileNotFoundError:
                pass
