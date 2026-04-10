from __future__ import annotations

from types import SimpleNamespace

from common.config import AppConfig
from domain_inventory.index import build_summary, collect_inventory


def test_collect_inventory_skips_zero_record_domains_and_wildcards(monkeypatch):
    domains = [
        SimpleNamespace(domain_name="empty.example.com", record_count=0),
        SimpleNamespace(domain_name="example.com", record_count=3),
    ]
    records = [
        SimpleNamespace(type="A", rr="@", value="1.1.1.1", ttl=600, line="default", status="Enable"),
        SimpleNamespace(type="A", rr="*", value="2.2.2.2", ttl=600, line="default", status="Enable"),
        SimpleNamespace(type="A", rr="paused", value="3.3.3.3", ttl=600, line="default", status="Disable"),
        SimpleNamespace(type="MX", rr="mail", value="mail.example.com", ttl=600, line="default", status="Enable"),
    ]

    monkeypatch.setattr("domain_inventory.index.list_managed_domains", lambda client: domains)
    monkeypatch.setattr("domain_inventory.index.get_authoritative_nameservers", lambda client, zone: ["dns1.hichina.com"])
    monkeypatch.setattr("domain_inventory.index.list_domain_records", lambda client, zone: records)
    monkeypatch.setattr(
        "domain_inventory.index.resolve_authoritatively",
        lambda fqdn, record_type, nameservers, timeout_sec: ("resolved", ["1.1.1.1"]),
    )

    config = AppConfig(
        oss_bucket="bucket",
        oss_prefix="prefix",
        inventory_csv_object_key="prefix/inventory/domains.csv",
        inventory_summary_object_key="prefix/inventory/summary.json",
        ssl_report_csv_object_key="prefix/ssl-report/ssl_report.csv",
        ssl_report_summary_object_key="prefix/ssl-report/summary.json",
        expiry_threshold_days=10,
        ssl_port=443,
        dns_timeout_sec=5,
        tls_timeout_sec=8,
        check_concurrency=20,
        oss_endpoint="https://oss-cn-hangzhou.aliyuncs.com",
        oss_region="cn-hangzhou",
        alidns_region_id="cn-hangzhou",
    )

    result = collect_inventory(object(), "run-1", "2026-04-09T00:00:00Z", config)

    assert len(result) == 2
    assert result[0].fqdn == "example.com"
    assert result[0].dns_status == "resolved"
    assert result[1].fqdn == "*.example.com"
    assert result[1].dns_status == "skipped"
    assert result[1].skip_reason == "wildcard_record"
    assert all(item.fqdn != "paused.example.com" for item in result)


def test_collect_inventory_only_skips_explicit_disable_status(monkeypatch):
    domains = [SimpleNamespace(domain_name="example.com", record_count=2)]
    records = [
        SimpleNamespace(type="A", rr="enabled-upper", value="1.1.1.1", ttl=600, line="default", status="ENABLE"),
        SimpleNamespace(type="A", rr="disabled", value="2.2.2.2", ttl=600, line="default", status="Disable"),
    ]

    monkeypatch.setattr("domain_inventory.index.list_managed_domains", lambda client: domains)
    monkeypatch.setattr("domain_inventory.index.get_authoritative_nameservers", lambda client, zone: ["dns1.hichina.com"])
    monkeypatch.setattr("domain_inventory.index.list_domain_records", lambda client, zone: records)
    monkeypatch.setattr(
        "domain_inventory.index.resolve_authoritatively",
        lambda fqdn, record_type, nameservers, timeout_sec: ("resolved", ["1.1.1.1"]),
    )

    config = AppConfig(
        oss_bucket="bucket",
        oss_prefix="prefix",
        inventory_csv_object_key="prefix/inventory/domains.csv",
        inventory_summary_object_key="prefix/inventory/summary.json",
        ssl_report_csv_object_key="prefix/ssl-report/ssl_report.csv",
        ssl_report_summary_object_key="prefix/ssl-report/summary.json",
        expiry_threshold_days=10,
        ssl_port=443,
        dns_timeout_sec=5,
        tls_timeout_sec=8,
        check_concurrency=20,
        oss_endpoint="https://oss-cn-hangzhou.aliyuncs.com",
        oss_region="cn-hangzhou",
        alidns_region_id="cn-hangzhou",
    )

    result = collect_inventory(object(), "run-1", "2026-04-09T00:00:00Z", config)

    assert [item.fqdn for item in result] == ["enabled-upper.example.com"]


def test_build_summary_counts_candidates():
    config = AppConfig(
        oss_bucket="bucket",
        oss_prefix="prefix",
        inventory_csv_object_key="prefix/inventory/domains.csv",
        inventory_summary_object_key="prefix/inventory/summary.json",
        ssl_report_csv_object_key="prefix/ssl-report/ssl_report.csv",
        ssl_report_summary_object_key="prefix/ssl-report/summary.json",
        expiry_threshold_days=10,
        ssl_port=443,
        dns_timeout_sec=5,
        tls_timeout_sec=8,
        check_concurrency=20,
        oss_endpoint="https://oss-cn-hangzhou.aliyuncs.com",
        oss_region="cn-hangzhou",
        alidns_region_id="cn-hangzhou",
    )
    rows = [
        SimpleNamespace(dns_status="resolved", skip_reason=""),
        SimpleNamespace(dns_status="resolved", skip_reason="wildcard_record"),
        SimpleNamespace(dns_status="unresolved", skip_reason=""),
    ]

    summary = build_summary(config, "run-1", rows, "inventory/run-1/domains.csv", "inventory/run-1/summary.json")
    assert summary["candidate_rows"] == 1
    assert summary["dns_status_counts"]["resolved"] == 2
