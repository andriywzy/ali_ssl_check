from __future__ import annotations

import os
from typing import Any

from common.models import Credentials


def _read_value(source: Any, *names: str) -> Any:
    if source is None:
        return None
    if isinstance(source, dict):
        for name in names:
            if name in source:
                return source[name]
        return None
    for name in names:
        if hasattr(source, name):
            return getattr(source, name)
    return None


def load_credentials(context: Any = None) -> Credentials:
    context_credentials = _read_value(context, "credentials", "credential")
    access_key_id = _read_value(
        context_credentials,
        "access_key_id",
        "accessKeyId",
        "AccessKeyId",
    ) or os.getenv("ALIBABA_CLOUD_ACCESS_KEY_ID")
    access_key_secret = _read_value(
        context_credentials,
        "access_key_secret",
        "accessKeySecret",
        "AccessKeySecret",
    ) or os.getenv("ALIBABA_CLOUD_ACCESS_KEY_SECRET")
    security_token = _read_value(
        context_credentials,
        "security_token",
        "securityToken",
        "SecurityToken",
    ) or os.getenv("ALIBABA_CLOUD_SECURITY_TOKEN")
    region_id = (
        _read_value(context, "region", "region_id", "regionId")
        or os.getenv("ALIBABA_CLOUD_REGION_ID")
        or os.getenv("FC_REGION")
    )

    if not access_key_id or not access_key_secret:
        raise ValueError(
            "Missing Alibaba Cloud credentials. In FC please bind an execution role; "
            "for local debugging set ALIBABA_CLOUD_ACCESS_KEY_ID and ALIBABA_CLOUD_ACCESS_KEY_SECRET."
        )

    return Credentials(
        access_key_id=access_key_id,
        access_key_secret=access_key_secret,
        security_token=security_token,
        region_id=region_id,
    )
