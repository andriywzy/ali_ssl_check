from __future__ import annotations

from typing import Iterable


SUPPORTED_RECORD_TYPES = {"A", "AAAA", "CNAME"}


def build_fqdn(rr: str, zone_domain: str) -> str:
    if rr == "@":
        return zone_domain
    return f"{rr}.{zone_domain}"


def resolve_authoritatively(
    fqdn: str,
    record_type: str,
    nameservers: Iterable[str],
    timeout_sec: int,
) -> tuple[str, list[str]]:
    import dns.exception
    import dns.resolver

    qtypes = [record_type]
    ns_ips = _resolve_nameserver_ips(nameservers, timeout_sec)
    if not ns_ips:
        return "unresolved", []

    resolver = dns.resolver.Resolver(configure=False)
    resolver.nameservers = ns_ips
    resolver.timeout = timeout_sec
    resolver.lifetime = timeout_sec

    for qtype in qtypes:
        try:
            answer = resolver.resolve(fqdn, qtype, raise_on_no_answer=False)
            if answer.rrset is None:
                continue
            values = [item.to_text() for item in answer]
            if values:
                return "resolved", values
        except dns.resolver.NXDOMAIN:
            return "unresolved", []
        except (dns.resolver.NoAnswer, dns.resolver.NoNameservers):
            continue
        except dns.exception.Timeout:
            return "unresolved", []

    return "unresolved", []


def _resolve_nameserver_ips(nameservers: Iterable[str], timeout_sec: int) -> list[str]:
    import dns.resolver

    resolver = dns.resolver.Resolver()
    resolver.timeout = timeout_sec
    resolver.lifetime = timeout_sec

    results: list[str] = []
    for nameserver in nameservers:
        target = nameserver.rstrip(".")
        for qtype in ("A", "AAAA"):
            try:
                answers = resolver.resolve(target, qtype, raise_on_no_answer=False)
            except Exception:
                continue
            if answers.rrset is None:
                continue
            results.extend(item.to_text() for item in answers)
    return list(dict.fromkeys(results))
