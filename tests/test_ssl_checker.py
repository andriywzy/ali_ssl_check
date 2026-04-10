from __future__ import annotations

from datetime import timedelta

from common.config import AppConfig
from common.models import SSLCheckResult
from common.ssl_checks import _fetch_leaf_certificate
from ssl_checker.index import _log_threshold_breach, _report_row, _resolve_run_id, build_summary, check_inventory_rows, handler


def test_check_inventory_rows_deduplicates_and_filters(monkeypatch):
    captured = []

    def fake_check_certificate(fqdn, port, threshold_days, timeout_sec, run_id):
        captured.append((fqdn, port, threshold_days, timeout_sec, run_id))
        return SSLCheckResult(
            run_id=run_id,
            fqdn=fqdn,
            port=port,
            status="ok",
            days_remaining=30,
            threshold_days=threshold_days,
            not_after_utc="2026-05-09T00:00:00Z",
            issuer="issuer",
            subject_cn=fqdn,
            san_count=1,
            error_message="",
            checked_at="2026-04-09T00:00:00Z",
        )

    monkeypatch.setattr("ssl_checker.index.check_certificate", fake_check_certificate)

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
        check_concurrency=4,
        oss_endpoint="https://oss-cn-hangzhou.aliyuncs.com",
        oss_region="cn-hangzhou",
        alidns_region_id="cn-hangzhou",
    )
    rows = [
        {"fqdn": "a.example.com", "dns_status": "resolved", "skip_reason": ""},
        {"fqdn": "a.example.com", "dns_status": "resolved", "skip_reason": ""},
        {"fqdn": "b.example.com", "dns_status": "resolved", "skip_reason": "wildcard_record"},
        {"fqdn": "c.example.com", "dns_status": "unresolved", "skip_reason": ""},
    ]

    results = check_inventory_rows(rows, "run-1", config)
    assert [item.fqdn for item in results] == ["a.example.com"]
    assert captured == [("a.example.com", 443, 10, 8, "run-1")]


def test_build_summary_reports_status_counts():
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
        check_concurrency=4,
        oss_endpoint="https://oss-cn-hangzhou.aliyuncs.com",
        oss_region="cn-hangzhou",
        alidns_region_id="cn-hangzhou",
    )
    results = [
        SSLCheckResult("run-1", "a.example.com", 443, "ok", 20, 10, "2026-05-01T00:00:00Z", "", "", 0, "", "2026-04-01T00:00:00Z"),
        SSLCheckResult("run-1", "b.example.com", 443, "error", "", 10, "", "", "", 0, "timeout", "2026-04-01T00:00:00Z"),
    ]

    summary = build_summary(config, "run-1", "inventory/run-1/domains.csv", "ssl/run-1/report.csv", "ssl/run-1/summary.json", results, 10)
    assert summary["checked_fqdn_count"] == 2
    assert summary["status_counts"] == {"ok": 1, "error": 1}


def test_resolve_run_id_prefers_csv_content():
    rows = [{"run_id": "run-from-csv"}, {"run_id": ""}]
    assert _resolve_run_id("ssl-check/inventory/domains.csv", rows) == "run-from-csv"


def test_handler_reads_fixed_inventory_key(monkeypatch):
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
        check_concurrency=4,
        oss_endpoint="https://oss-cn-hangzhou.aliyuncs.com",
        oss_region="cn-hangzhou",
        alidns_region_id="cn-hangzhou",
    )

    class FakeOSSStore:
        def __init__(self, *_args, **_kwargs):
            self.get_calls = []
            self.put_calls = []

        def get_text(self, key):
            self.get_calls.append(key)
            return "run_id,fqdn,dns_status,skip_reason\nrun-1,a.example.com,resolved,\n"

        def put_text(self, key, content, content_type):
            self.put_calls.append((key, content_type))

        def put_json(self, key, payload):
            self.put_calls.append((key, payload["run_id"]))

    fake_store = FakeOSSStore()

    monkeypatch.setattr("ssl_checker.index.AppConfig.from_env", lambda: config)
    monkeypatch.setattr("ssl_checker.index.load_credentials", lambda context: object())
    monkeypatch.setattr("ssl_checker.index.OSSStore", lambda config, credentials: fake_store)
    monkeypatch.setattr("ssl_checker.index.check_inventory_rows", lambda rows, run_id, config: [])

    summary = handler(event=None, context=None)

    assert fake_store.get_calls == ["prefix/inventory/domains.csv"]
    assert summary["inventory_key"] == "prefix/inventory/domains.csv"


def test_fetch_leaf_certificate_decodes_binary_form(monkeypatch):
    class FakeTlsSocket:
        def getpeercert(self, binary_form=False):
            if binary_form:
                return b"fake-der"
            return {}

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

    class FakeRawSocket:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

    class FakeSSLContext:
        def __init__(self, _protocol):
            self.check_hostname = True
            self.verify_mode = None

        def wrap_socket(self, sock, server_hostname):
            assert server_hostname == "a.example.com"
            return FakeTlsSocket()

    monkeypatch.setattr("common.ssl_checks.socket.create_connection", lambda addr, timeout: FakeRawSocket())
    monkeypatch.setattr("common.ssl_checks.ssl.SSLContext", FakeSSLContext)
    monkeypatch.setattr("common.ssl_checks._decode_der_certificate", lambda der: {"notAfter": "Apr 09 00:00:00 2026 GMT"})

    cert = _fetch_leaf_certificate("a.example.com", 443, 8)
    assert cert["notAfter"] == "Apr 09 00:00:00 2026 GMT"


def test_report_row_only_keeps_days_remaining_for_ok():
    ok_result = SSLCheckResult("run-1", "ok.example.com", 443, "ok", 20, 10, "2026-05-01T00:00:00Z", "", "", 0, "", "2026-04-01T00:00:00Z")
    expiring_result = SSLCheckResult("run-1", "exp.example.com", 443, "expiring", 3, 10, "2026-04-12T00:00:00Z", "", "", 0, "", "2026-04-01T00:00:00Z")

    assert _report_row(ok_result).days_remaining == 20
    assert _report_row(expiring_result).days_remaining == ""


def test_log_threshold_breach_logs_when_status_is_expiring(caplog):
    result = SSLCheckResult(
        "run-1",
        "exp.example.com",
        443,
        "expiring",
        3,
        10,
        "2026-04-12T00:00:00Z",
        "",
        "",
        0,
        "",
        "2026-04-01T00:00:00Z",
    )

    _log_threshold_breach(result)

    assert '"event": "certificate_below_threshold"' in caplog.text
    assert '"fqdn": "exp.example.com"' in caplog.text


def test_log_threshold_breach_skips_non_expiring_status(caplog):
    result = SSLCheckResult(
        "run-1",
        "expired.example.com",
        443,
        "expired",
        -1,
        10,
        "2026-04-01T00:00:00Z",
        "",
        "",
        0,
        "",
        "2026-04-01T00:00:00Z",
    )

    _log_threshold_breach(result)

    assert caplog.text == ""
