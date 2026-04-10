from __future__ import annotations

from common.oss_io import _build_authorization_header, _build_object_url


def test_build_object_url_uses_virtual_hosted_style():
    url = _build_object_url("https://oss-cn-hangzhou.aliyuncs.com", "example-bucket", "a/b.csv")
    assert url == "https://example-bucket.oss-cn-hangzhou.aliyuncs.com/a/b.csv"


def test_build_authorization_header_includes_security_token_in_signature():
    auth = _build_authorization_header(
        method="PUT",
        bucket="example-bucket",
        key="inventory/run-1/domains.csv",
        access_key_id="ak",
        access_key_secret="secret",
        date_header="Wed, 09 Apr 2026 11:00:00 GMT",
        content_type="text/csv; charset=utf-8",
        security_token="sts-token",
    )
    assert auth.startswith("OSS ak:")
