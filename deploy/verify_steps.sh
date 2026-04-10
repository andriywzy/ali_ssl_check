#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARS_FILE="${SCRIPT_DIR}/vars.env"
RENDER_SCRIPT="${SCRIPT_DIR}/render_templates.sh"
RENDERED_DIR="${SCRIPT_DIR}/rendered"

STAGE="${1:-all}"

PASS_COUNT=0
FAIL_COUNT=0

usage() {
  cat <<'EOF'
Usage:
  ./deploy/verify_steps.sh [all|local|ram|fc|invoke|sls|etl|alert]

Stages:
  local   Verify vars + template rendering + rendered JSON validity
  ram     Verify RAM roles/policies and policy attachment
  fc      Verify FC service/functions/(optional timer trigger)
  invoke  Verify OSS output objects exist (inventory + ssl report)
  sls     Verify target SLS logstore + index
  etl     Verify ETL task exists and print ETL status
  alert   Verify alert exists and print alert status
  all     Run all checks in order
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing command: $1"
    exit 1
  fi
}

load_env() {
  if [[ ! -f "${VARS_FILE}" ]]; then
    echo "missing vars file: ${VARS_FILE}"
    echo "copy deploy/templates/vars.env.tpl to deploy/vars.env first."
    exit 1
  fi
  set -a
  # shellcheck source=/dev/null
  source "${VARS_FILE}"
  set +a
}

aliyun_cmd() {
  if [[ -n "${ALIYUN_PROFILE:-}" ]]; then
    aliyun --profile "${ALIYUN_PROFILE}" --region "${ALIYUN_REGION}" "$@"
  else
    aliyun --region "${ALIYUN_REGION}" "$@"
  fi
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "[PASS] $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "[FAIL] $1"
}

run_check() {
  local desc="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    pass "${desc}"
    if [[ -n "${output}" ]]; then
      echo "${output}"
    fi
  else
    fail "${desc}"
    echo "${output}"
  fi
}

check_local() {
  echo "== verify: local =="
  run_check "render templates" "${RENDER_SCRIPT}" "${VARS_FILE}"

  local required_files=(
    "${RENDERED_DIR}/fc/service.create.json"
    "${RENDERED_DIR}/fc/function.domain_inventory.create.json"
    "${RENDERED_DIR}/fc/function.ssl_checker.create.json"
    "${RENDERED_DIR}/fc/trigger.timer.domain_inventory.json"
    "${RENDERED_DIR}/sls/logstore.target.create.json"
    "${RENDERED_DIR}/sls/logstore.target.index.json"
    "${RENDERED_DIR}/sls/etl.create.json"
    "${RENDERED_DIR}/sls/alert.create.json"
    "${RENDERED_DIR}/sls/etl.rewrite.spl"
    "${RENDERED_DIR}/sls/alert.query.sql"
    "${RENDERED_DIR}/sls/notification.content.md"
    "${RENDERED_DIR}/sls/action.policy.dsl"
    "${RENDERED_DIR}/sls/console.bootstrap.md"
  )

  for file in "${required_files[@]}"; do
    if [[ -f "${file}" ]]; then
      pass "rendered file exists: ${file#${SCRIPT_DIR}/}"
    else
      fail "rendered file missing: ${file#${SCRIPT_DIR}/}"
    fi
  done

  local json_files=(
    "${RENDERED_DIR}/fc/service.create.json"
    "${RENDERED_DIR}/fc/function.domain_inventory.create.json"
    "${RENDERED_DIR}/fc/function.ssl_checker.create.json"
    "${RENDERED_DIR}/fc/trigger.timer.domain_inventory.json"
    "${RENDERED_DIR}/sls/logstore.target.create.json"
    "${RENDERED_DIR}/sls/logstore.target.index.json"
    "${RENDERED_DIR}/sls/etl.create.json"
    "${RENDERED_DIR}/sls/alert.create.json"
  )
  for json_file in "${json_files[@]}"; do
    run_check "valid json: ${json_file#${SCRIPT_DIR}/}" jq empty "${json_file}"
  done

  if rg -n '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "${RENDERED_DIR}" >/tmp/verify_unresolved_vars.txt 2>/dev/null; then
    fail "rendered output still has unresolved \${VARS}"
    cat /tmp/verify_unresolved_vars.txt
  else
    pass "no unresolved \${VARS} in rendered output"
  fi
}

check_ram() {
  echo "== verify: ram =="
  run_check "role exists: ${RAM_ROLE_DOMAIN_INVENTORY}" \
    aliyun_cmd ram GetRole --RoleName "${RAM_ROLE_DOMAIN_INVENTORY}"
  run_check "role exists: ${RAM_ROLE_SSL_CHECKER}" \
    aliyun_cmd ram GetRole --RoleName "${RAM_ROLE_SSL_CHECKER}"
  run_check "policy exists: ${RAM_POLICY_DOMAIN_INVENTORY}" \
    aliyun_cmd ram GetPolicy --PolicyType Custom --PolicyName "${RAM_POLICY_DOMAIN_INVENTORY}"
  run_check "policy exists: ${RAM_POLICY_SSL_CHECKER}" \
    aliyun_cmd ram GetPolicy --PolicyType Custom --PolicyName "${RAM_POLICY_SSL_CHECKER}"
  run_check "role policy attachments: ${RAM_ROLE_DOMAIN_INVENTORY}" \
    aliyun_cmd ram ListPoliciesForRole --RoleName "${RAM_ROLE_DOMAIN_INVENTORY}"
  run_check "role policy attachments: ${RAM_ROLE_SSL_CHECKER}" \
    aliyun_cmd ram ListPoliciesForRole --RoleName "${RAM_ROLE_SSL_CHECKER}"
}

check_fc() {
  echo "== verify: fc =="
  run_check "service exists: ${FC_SERVICE_NAME}" \
    aliyun_cmd fc-open GetService --serviceName "${FC_SERVICE_NAME}"
  run_check "function exists: ${FC_DOMAIN_INVENTORY_FUNCTION_NAME}" \
    aliyun_cmd fc-open GetFunction --serviceName "${FC_SERVICE_NAME}" --functionName "${FC_DOMAIN_INVENTORY_FUNCTION_NAME}"
  run_check "function exists: ${FC_SSL_CHECKER_FUNCTION_NAME}" \
    aliyun_cmd fc-open GetFunction --serviceName "${FC_SERVICE_NAME}" --functionName "${FC_SSL_CHECKER_FUNCTION_NAME}"

  if [[ "${FC_TRIGGER_TIMER_ENABLED}" == "true" ]]; then
    run_check "timer trigger exists: ${FC_TRIGGER_TIMER_NAME}" \
      aliyun_cmd fc-open GetTrigger \
      --serviceName "${FC_SERVICE_NAME}" \
      --functionName "${FC_DOMAIN_INVENTORY_FUNCTION_NAME}" \
      --triggerName "${FC_TRIGGER_TIMER_NAME}"
  else
    echo "[INFO] timer verification skipped because FC_TRIGGER_TIMER_ENABLED=false"
  fi
}

check_invoke_outputs() {
  echo "== verify: invoke outputs =="
  run_check "inventory csv exists in oss" \
    aliyun oss stat "oss://${OSS_BUCKET}/${INVENTORY_CSV_OBJECT_KEY}"
  run_check "inventory summary exists in oss" \
    aliyun oss stat "oss://${OSS_BUCKET}/${INVENTORY_SUMMARY_OBJECT_KEY}"
  run_check "ssl report csv exists in oss" \
    aliyun oss stat "oss://${OSS_BUCKET}/${SSL_REPORT_CSV_OBJECT_KEY}"
  run_check "ssl report summary exists in oss" \
    aliyun oss stat "oss://${OSS_BUCKET}/${SSL_REPORT_SUMMARY_OBJECT_KEY}"
}

check_sls() {
  echo "== verify: sls =="
  run_check "target logstore exists: ${SLS_TARGET_LOGSTORE}" \
    aliyun_cmd sls GetLogStore --project "${SLS_PROJECT}" --logstore "${SLS_TARGET_LOGSTORE}"
  run_check "target logstore index exists" \
    aliyun_cmd sls GetIndex --project "${SLS_PROJECT}" --logstore "${SLS_TARGET_LOGSTORE}"
}

check_etl() {
  echo "== verify: etl =="
  local etl_json
  if etl_json="$(aliyun_cmd sls GetETL --project "${SLS_PROJECT}" --etlName "${SLS_ETL_NAME}" 2>/dev/null)"; then
    pass "etl exists: ${SLS_ETL_NAME}"
    echo "${etl_json}" | jq -r '.name, .displayName, ("status=" + (.status|tostring))'
  else
    fail "etl exists: ${SLS_ETL_NAME}"
  fi
}

check_alert() {
  echo "== verify: alert =="
  local alert_json
  if alert_json="$(aliyun_cmd sls GetAlert --project "${SLS_PROJECT}" --alertName "${SLS_ALERT_NAME}" 2>/dev/null)"; then
    pass "alert exists: ${SLS_ALERT_NAME}"
    echo "${alert_json}" | jq -r '.name, .displayName, ("status=" + (.status|tostring))'
  else
    fail "alert exists: ${SLS_ALERT_NAME}"
  fi
}

summary() {
  echo "== verify summary =="
  echo "pass: ${PASS_COUNT}"
  echo "fail: ${FAIL_COUNT}"
  if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    exit 1
  fi
}

main() {
  if [[ "${STAGE}" == "-h" || "${STAGE}" == "--help" || "${STAGE}" == "help" ]]; then
    usage
    exit 0
  fi

  require_cmd aliyun
  require_cmd jq
  require_cmd envsubst
  require_cmd rg
  load_env

  case "${STAGE}" in
    local)
      check_local
      ;;
    ram)
      check_ram
      ;;
    fc)
      check_fc
      ;;
    invoke)
      check_invoke_outputs
      ;;
    sls)
      check_sls
      ;;
    etl)
      check_etl
      ;;
    alert)
      check_alert
      ;;
    all)
      check_local
      check_ram
      check_fc
      check_invoke_outputs
      check_sls
      check_etl
      check_alert
      ;;
    *)
      echo "unknown stage: ${STAGE}"
      usage
      exit 1
      ;;
  esac

  summary
}

main "$@"
