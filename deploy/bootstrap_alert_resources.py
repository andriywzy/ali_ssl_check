#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def log(message: str) -> None:
    print(message, file=sys.stderr)


def load_aliyun_profile(profile_name: str) -> dict[str, str]:
    config_path = Path.home() / ".aliyun" / "config.json"
    if not config_path.exists():
        fail(f"aliyun cli config not found: {config_path}")

    data = json.loads(config_path.read_text(encoding="utf-8"))
    profiles = data.get("profiles", [])
    for profile in profiles:
        if profile.get("name") == profile_name:
            return profile
    fail(f"aliyun profile not found: {profile_name}")
    return {}


def normalize_text_file(path: Path) -> str:
    return path.read_text(encoding="utf-8").replace("\r\n", "\n")


def validate_required(name: str, value: str) -> None:
    if not value or value.strip() == "":
        fail(f"{name} is required")


def normalize_resource_id(value: str, default_value: str) -> str:
    normalized = (value or "").strip()
    if not normalized or normalized == "replace-in-console":
        return default_value
    return normalized


def list_all_records(client, resource_name: str):
    records = []
    offset = 0
    size = 100
    while True:
        resp = client.list_resource_records(resource_name, offset=offset, size=size)
        batch = resp.get_records()
        records.extend(batch)
        count = resp.get_count()
        total = resp.get_total()
        if count <= 0 or offset + count >= total:
            break
        offset += count
    return records


def resolve_contact_group_id(client, explicit_id: str, group_name: str) -> str:
    if explicit_id:
        return explicit_id

    records = list_all_records(client, "sls.common.user_group")
    for record in records:
        value = record.get_value() or {}
        user_group_id = (value.get("user_group_id") or "").strip()
        user_group_name = (value.get("user_group_name") or "").strip()
        tag = (record.get_tag() or "").strip()
        record_id = (record.get_record_id() or "").strip()
        if group_name in {user_group_id, user_group_name, tag, record_id}:
            return user_group_id or record_id

    return group_name


def build_content_template_value(template_id: str, template_name: str, content: str) -> dict:
    return {
        "template_id": template_id,
        "template_name": template_name,
        "is_default": False,
        "templates": {
            "sms": {"locale": "zh-CN", "content": content},
            "email": {"locale": "zh-CN", "subject": "SSL 证书临期告警", "content": content},
            "webhook": {"locale": "zh-CN", "content": content, "send_type": "batch", "limit": 0},
            "fc": {"locale": "zh-CN", "content": content, "send_type": "merged", "limit": 0},
        },
    }


def build_action_policy_value(action_policy_id: str, action_policy_name: str, action_dsl: str) -> dict:
    return {
        "action_policy_id": action_policy_id,
        "action_policy_name": action_policy_name,
        "labels": {},
        "is_default": False,
        "primary_policy_script": action_dsl,
        "secondary_policy_script": "",
        "escalation_start_enabled": False,
        "escalation_start_timeout": "10s",
        "escalation_inprogress_enabled": False,
        "escalation_inprogress_timeout": "10s",
        "escalation_enabled": False,
        "escalation_timeout": "4h0m0s",
    }


def ensure_content_template(client, ResourceRecord, template_id: str, template_name: str, content: str, check_only: bool) -> str:
    if check_only:
        client.get_resource_record("sls.alert.content_template", template_id)
        return template_id

    payload_value = build_content_template_value(template_id, template_name, content)
    record = ResourceRecord(record_id=template_id, tag=template_name, value=payload_value)
    client.upsert_resource_record("sls.alert.content_template", [record])
    return template_id


def ensure_action_policy(
    client,
    ResourceRecord,
    action_policy_id: str,
    action_policy_name: str,
    action_dsl_template: str,
    template_id: str,
    contact_group_id: str,
    check_only: bool,
) -> str:
    if check_only:
        client.get_resource_record("sls.alert.action_policy", action_policy_id)
        return action_policy_id

    action_dsl = (
        action_dsl_template.replace("__CONTENT_TEMPLATE_ID__", template_id)
        .replace("${CONTENT_TEMPLATE_ID}", template_id)
        .replace("__CONTACT_GROUP_ID__", contact_group_id)
    )
    payload_value = build_action_policy_value(action_policy_id, action_policy_name, action_dsl)
    record = ResourceRecord(record_id=action_policy_id, tag=action_policy_name, value=payload_value)
    client.upsert_resource_record("sls.alert.action_policy", [record])
    return action_policy_id


def main() -> None:
    parser = argparse.ArgumentParser(description="Bootstrap SLS alert content template and action policy.")
    parser.add_argument("--content-file", required=True, help="Rendered markdown template file path")
    parser.add_argument("--action-file", required=True, help="Rendered action DSL file path")
    parser.add_argument("--check-only", action="store_true", help="Only check resource records exist")
    args = parser.parse_args()

    profile = os.getenv("ALIYUN_PROFILE", "default").strip()
    region = os.getenv("ALIYUN_REGION", "").strip()
    project = os.getenv("SLS_PROJECT", "").strip()

    template_id = normalize_resource_id(os.getenv("CONTENT_TEMPLATE_ID", ""), "ssl-check")
    template_name = (os.getenv("CONTENT_TEMPLATE_NAME") or "证书临期模版").strip()
    action_policy_id = normalize_resource_id(os.getenv("ACTION_POLICY_ID", ""), "ssl-check-action")
    action_policy_name = (os.getenv("ACTION_POLICY_NAME") or "证书临期行动策略").strip()
    contact_group_id = (os.getenv("ALERT_CONTACT_GROUP_ID") or "").strip()
    contact_group_name = (os.getenv("ALERT_CONTACT_GROUP_NAME") or "Default Contact Group").strip()

    validate_required("ALIYUN_REGION", region)
    validate_required("SLS_PROJECT", project)
    validate_required("CONTENT_TEMPLATE_ID", template_id)
    validate_required("CONTENT_TEMPLATE_NAME", template_name)
    validate_required("ACTION_POLICY_ID", action_policy_id)
    validate_required("ACTION_POLICY_NAME", action_policy_name)

    profile_obj = load_aliyun_profile(profile)
    access_key_id = profile_obj.get("access_key_id", "").strip()
    access_key_secret = profile_obj.get("access_key_secret", "").strip()
    if not access_key_id or not access_key_secret:
        fail(f"profile '{profile}' does not contain access key credentials")

    content_path = Path(args.content_file)
    action_path = Path(args.action_file)
    if not content_path.exists():
        fail(f"content template file not found: {content_path}")
    if not action_path.exists():
        fail(f"action policy file not found: {action_path}")

    try:
        from aliyun.log import LogClient  # type: ignore
        from aliyun.log.resource_params import ResourceRecord  # type: ignore
    except Exception as exc:
        fail(
            "missing dependency: aliyun-log-python-sdk\n"
            "install it with: python3 -m pip install aliyun-log-python-sdk\n"
            f"details: {exc}"
        )

    endpoint = f"{project}.{region}.log.aliyuncs.com"
    client = LogClient(endpoint, access_key_id, access_key_secret)

    notification_content = normalize_text_file(content_path)
    action_dsl_template = normalize_text_file(action_path).strip()
    if not args.check_only and not action_dsl_template:
        fail("action policy dsl is empty")

    resolved_contact_group_id = resolve_contact_group_id(client, contact_group_id, contact_group_name)
    validate_required("resolved contact group id", resolved_contact_group_id)

    content_template_id = ensure_content_template(
        client,
        ResourceRecord,
        template_id=template_id,
        template_name=template_name,
        content=notification_content,
        check_only=args.check_only,
    )
    resolved_action_policy_id = ensure_action_policy(
        client,
        ResourceRecord,
        action_policy_id=action_policy_id,
        action_policy_name=action_policy_name,
        action_dsl_template=action_dsl_template,
        template_id=content_template_id,
        contact_group_id=resolved_contact_group_id,
        check_only=args.check_only,
    )

    mode = "checked" if args.check_only else "upserted"
    log(f"{mode} content template: id={content_template_id}, name={template_name}")
    log(f"{mode} action policy: id={resolved_action_policy_id}, name={action_policy_name}")
    log(f"resolved contact group id: {resolved_contact_group_id} (from '{contact_group_name}')")

    print(
        json.dumps(
            {
                "content_template_id": content_template_id,
                "action_policy_id": resolved_action_policy_id,
                "contact_group_id": resolved_contact_group_id,
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
