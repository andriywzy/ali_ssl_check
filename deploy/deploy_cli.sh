#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VARS_FILE="${SCRIPT_DIR}/vars.env"
RENDER_SCRIPT="${SCRIPT_DIR}/render_templates.sh"
RENDERED_DIR="${SCRIPT_DIR}/rendered"

ACTION="${1:-all}"

usage() {
  cat <<'EOF'
Usage:
  ./deploy/deploy_cli.sh [all|render|ram|fc|invoke|sls|etl|alert|verify]

Stages:
  render  Render all templates from deploy/templates -> deploy/rendered
  ram     Create RAM roles/policies and attach policies
  sls     Create/update SLS project, source/target logstores, and indexes
  fc      Upload code packages, create/update FC3 functions/optional timer trigger
  invoke  Invoke domain_inventory and ssl_checker for smoke validation
  etl     Create/update and start SLS ETL rewrite task
  alert   Create/update and enable SLS alert
  verify  Verify deployment steps (delegates to ./deploy/verify_steps.sh)
  all     Execute: render -> ram -> sls -> fc -> invoke -> etl -> alert
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing command: $1"
    exit 1
  fi
}

json_body() {
  local file="$1"
  jq -c . "${file}"
}

require_env() {
  local name="$1"
  local value="${!name:-}"
  if [[ -z "${value}" ]]; then
    echo "missing required env: ${name}"
    exit 1
  fi
}

validate_fc_runtime() {
  case "${FC_RUNTIME:-}" in
    python3|python3.9|python3.10|python3.12)
      ;;
    *)
      cat <<EOF
invalid FC_RUNTIME: ${FC_RUNTIME:-<empty>}
supported values for this project: python3, python3.9, python3.10, python3.12
recommended: python3.12
EOF
      exit 1
      ;;
  esac
}

validate_uint_env() {
  local name="$1"
  local value="${!name:-}"
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    echo "invalid numeric env: ${name}=${value}"
    echo "expect an unsigned integer."
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

run_ignore_already_exists() {
  local expected_error="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    [[ -n "${output}" ]] && echo "${output}"
    return 0
  fi

  if echo "${output}" | grep -q "${expected_error}"; then
    echo "${output}"
    return 0
  fi

  echo "${output}"
  return 1
}

ensure_sls_project_exists() {
  local project_name="$1"
  local project_body_file="$2"
  local get_output

  echo "[sls] ensure project: ${project_name}"
  if ! aliyun_cmd sls GetProject --project "${project_name}" >/dev/null 2>&1; then
    run_ignore_already_exists "ProjectAlreadyExist" \
      aliyun_cmd sls CreateProject \
      --body "$(json_body "${project_body_file}")"
  fi

  if ! get_output="$(aliyun_cmd sls GetProject --project "${project_name}" 2>&1)"; then
    if echo "${get_output}" | grep -q "The project does not belong to you"; then
      cat <<EOF
[sls] project name is not usable by current account: ${project_name}
This project name already exists under another account.
Please change both FC_LOG_PROJECT and SLS_PROJECT in deploy/vars.env to a unique value, for example:
  ssl-check-${ACCOUNT_ID}
Then rerun:
  ./deploy/render_templates.sh
  ./deploy/deploy_cli.sh sls
EOF
      exit 1
    fi
    echo "${get_output}"
    exit 1
  fi
}

ensure_sls_logstore_exists() {
  local project_name="$1"
  local logstore_name="$2"
  local logstore_body_file="$3"

  echo "[sls] ensure logstore: ${project_name}/${logstore_name}"
  if ! aliyun_cmd sls GetLogStore --project "${project_name}" --logstore "${logstore_name}" >/dev/null 2>&1; then
    run_ignore_already_exists "LogStoreAlreadyExist" \
      aliyun_cmd sls CreateLogStore \
      --project "${project_name}" \
      --body "$(json_body "${logstore_body_file}")"
  fi

  aliyun_cmd sls GetLogStore --project "${project_name}" --logstore "${logstore_name}" >/dev/null
}

ensure_sls_index_exists() {
  local project_name="$1"
  local logstore_name="$2"
  local index_body_file="$3"

  echo "[sls] ensure index: ${project_name}/${logstore_name}"
  if aliyun_cmd sls GetIndex --project "${project_name}" --logstore "${logstore_name}" >/dev/null 2>&1; then
    aliyun_cmd sls UpdateIndex \
      --project "${project_name}" \
      --logstore "${logstore_name}" \
      --body "$(json_body "${index_body_file}")"
  else
    aliyun_cmd sls CreateIndex \
      --project "${project_name}" \
      --logstore "${logstore_name}" \
      --body "$(json_body "${index_body_file}")"
  fi
}

render_all() {
  echo "[render] rendering templates..."
  "${RENDER_SCRIPT}" "${VARS_FILE}"
}

prepare_policy_docs() {
  mkdir -p "${RENDERED_DIR}/policies"
  sed \
    -e "s#<your-bucket>#${OSS_BUCKET}#g" \
    -e "s#<your-prefix>#${OSS_PREFIX}#g" \
    -e "s#<log-project>#${FC_LOG_PROJECT}#g" \
    -e "s#<log-logstore>#${FC_LOG_LOGSTORE}#g" \
    "${ROOT_DIR}/policies/domain-inventory-role-policy.json" \
    >"${RENDERED_DIR}/policies/domain-inventory-role-policy.json"

  sed \
    -e "s#<your-bucket>#${OSS_BUCKET}#g" \
    -e "s#<your-prefix>#${OSS_PREFIX}#g" \
    -e "s#<log-project>#${FC_LOG_PROJECT}#g" \
    -e "s#<log-logstore>#${FC_LOG_LOGSTORE}#g" \
    "${ROOT_DIR}/policies/ssl-checker-role-policy.json" \
    >"${RENDERED_DIR}/policies/ssl-checker-role-policy.json"
}

ensure_custom_policy() {
  local policy_name="$1"
  local description="$2"
  local policy_file="$3"

  if ! aliyun_cmd ram GetPolicy --PolicyType Custom --PolicyName "${policy_name}" >/dev/null 2>&1; then
    aliyun_cmd ram CreatePolicy \
      --PolicyName "${policy_name}" \
      --Description "${description}" \
      --PolicyDocument "$(cat "${policy_file}")"
    return 0
  fi

  aliyun_cmd ram CreatePolicyVersion \
    --PolicyName "${policy_name}" \
    --SetAsDefault true \
    --RotateStrategy DeleteOldestNonDefaultVersionWhenLimitExceeded \
    --PolicyDocument "$(cat "${policy_file}")" >/dev/null
}

validate_log_binding() {
  require_env FC_LOG_PROJECT
  require_env FC_LOG_LOGSTORE
  require_env SLS_PROJECT
  require_env SLS_SOURCE_LOGSTORE

  if [[ "${FC_LOG_PROJECT}" != "${SLS_PROJECT}" ]]; then
    echo "FC_LOG_PROJECT and SLS_PROJECT should match for this deployment."
    echo "FC_LOG_PROJECT=${FC_LOG_PROJECT}"
    echo "SLS_PROJECT=${SLS_PROJECT}"
    exit 1
  fi

  if [[ "${FC_LOG_LOGSTORE}" != "${SLS_SOURCE_LOGSTORE}" ]]; then
    echo "FC_LOG_LOGSTORE and SLS_SOURCE_LOGSTORE should match for this deployment."
    echo "FC_LOG_LOGSTORE=${FC_LOG_LOGSTORE}"
    echo "SLS_SOURCE_LOGSTORE=${SLS_SOURCE_LOGSTORE}"
    exit 1
  fi
}

stage_ram() {
  validate_log_binding
  echo "[ram] prepare policy docs..."
  prepare_policy_docs

  echo "[ram] ensure role: ${RAM_ROLE_DOMAIN_INVENTORY}"
  if ! aliyun_cmd ram GetRole --RoleName "${RAM_ROLE_DOMAIN_INVENTORY}" >/dev/null 2>&1; then
    aliyun_cmd ram CreateRole \
      --RoleName "${RAM_ROLE_DOMAIN_INVENTORY}" \
      --Description "execution role for domain inventory function" \
      --AssumeRolePolicyDocument "$(cat "${ROOT_DIR}/policies/fc-execution-trust-policy.json")"
  fi

  echo "[ram] ensure role: ${RAM_ROLE_SSL_CHECKER}"
  if ! aliyun_cmd ram GetRole --RoleName "${RAM_ROLE_SSL_CHECKER}" >/dev/null 2>&1; then
    aliyun_cmd ram CreateRole \
      --RoleName "${RAM_ROLE_SSL_CHECKER}" \
      --Description "execution role for ssl checker function" \
      --AssumeRolePolicyDocument "$(cat "${ROOT_DIR}/policies/fc-execution-trust-policy.json")"
  fi

  echo "[ram] ensure policy: ${RAM_POLICY_DOMAIN_INVENTORY}"
  ensure_custom_policy \
    "${RAM_POLICY_DOMAIN_INVENTORY}" \
    "domain inventory minimal policy" \
    "${RENDERED_DIR}/policies/domain-inventory-role-policy.json"

  echo "[ram] ensure policy: ${RAM_POLICY_SSL_CHECKER}"
  ensure_custom_policy \
    "${RAM_POLICY_SSL_CHECKER}" \
    "ssl checker minimal policy" \
    "${RENDERED_DIR}/policies/ssl-checker-role-policy.json"

  echo "[ram] attach policy to roles..."
  aliyun_cmd ram AttachPolicyToRole \
    --PolicyType Custom \
    --PolicyName "${RAM_POLICY_DOMAIN_INVENTORY}" \
    --RoleName "${RAM_ROLE_DOMAIN_INVENTORY}" >/dev/null || true

  aliyun_cmd ram AttachPolicyToRole \
    --PolicyType Custom \
    --PolicyName "${RAM_POLICY_SSL_CHECKER}" \
    --RoleName "${RAM_ROLE_SSL_CHECKER}" >/dev/null || true
}

upload_packages() {
  local domain_object="oss://${FC_CODE_OSS_BUCKET}/${FC_CODE_OBJECT_PREFIX}/${FC_DOMAIN_INVENTORY_FUNCTION_NAME}.zip"
  local ssl_object="oss://${FC_CODE_OSS_BUCKET}/${FC_CODE_OBJECT_PREFIX}/${FC_SSL_CHECKER_FUNCTION_NAME}.zip"

  if [[ ! -f "${ROOT_DIR}/${DOMAIN_INVENTORY_PACKAGE_PATH}" ]]; then
    echo "missing package: ${ROOT_DIR}/${DOMAIN_INVENTORY_PACKAGE_PATH}"
    exit 1
  fi
  if [[ ! -f "${ROOT_DIR}/${SSL_CHECKER_PACKAGE_PATH}" ]]; then
    echo "missing package: ${ROOT_DIR}/${SSL_CHECKER_PACKAGE_PATH}"
    exit 1
  fi

  echo "[fc] upload domain_inventory package -> ${domain_object}"
  aliyun oss cp "${ROOT_DIR}/${DOMAIN_INVENTORY_PACKAGE_PATH}" "${domain_object}" --force

  echo "[fc] upload ssl_checker package -> ${ssl_object}"
  aliyun oss cp "${ROOT_DIR}/${SSL_CHECKER_PACKAGE_PATH}" "${ssl_object}" --force
}

stage_fc() {
  require_env FC_RUNTIME
  require_env FC_LOG_PROJECT
  require_env FC_LOG_LOGSTORE
  validate_log_binding
  validate_fc_runtime
  echo "[fc] preflight sls resources"
  stage_sls
  render_all
  upload_packages

  echo "[fc] ensure function: ${FC_DOMAIN_INVENTORY_FUNCTION_NAME}"
  if aliyun_cmd fc GetFunction --functionName "${FC_DOMAIN_INVENTORY_FUNCTION_NAME}" >/dev/null 2>&1; then
    jq 'del(.functionName)' "${RENDERED_DIR}/fc/function.domain_inventory.create.json" >"${RENDERED_DIR}/fc/function.domain_inventory.update.json"
    aliyun_cmd fc UpdateFunction \
      --functionName "${FC_DOMAIN_INVENTORY_FUNCTION_NAME}" \
      --body "$(cat "${RENDERED_DIR}/fc/function.domain_inventory.update.json")"
  else
    aliyun_cmd fc CreateFunction \
      --body "$(cat "${RENDERED_DIR}/fc/function.domain_inventory.create.json")"
  fi

  echo "[fc] ensure function: ${FC_SSL_CHECKER_FUNCTION_NAME}"
  if aliyun_cmd fc GetFunction --functionName "${FC_SSL_CHECKER_FUNCTION_NAME}" >/dev/null 2>&1; then
    jq 'del(.functionName)' "${RENDERED_DIR}/fc/function.ssl_checker.create.json" >"${RENDERED_DIR}/fc/function.ssl_checker.update.json"
    aliyun_cmd fc UpdateFunction \
      --functionName "${FC_SSL_CHECKER_FUNCTION_NAME}" \
      --body "$(cat "${RENDERED_DIR}/fc/function.ssl_checker.update.json")"
  else
    aliyun_cmd fc CreateFunction \
      --body "$(cat "${RENDERED_DIR}/fc/function.ssl_checker.create.json")"
  fi

  if [[ "${FC_TRIGGER_TIMER_ENABLED}" == "true" ]]; then
    echo "[fc] ensure timer trigger: ${FC_TRIGGER_TIMER_NAME}"
    if aliyun_cmd fc GetTrigger \
      --functionName "${FC_DOMAIN_INVENTORY_FUNCTION_NAME}" \
      --triggerName "${FC_TRIGGER_TIMER_NAME}" >/dev/null 2>&1; then
      aliyun_cmd fc UpdateTrigger \
        --functionName "${FC_DOMAIN_INVENTORY_FUNCTION_NAME}" \
        --triggerName "${FC_TRIGGER_TIMER_NAME}" \
        --body "$(cat "${RENDERED_DIR}/fc/trigger.timer.domain_inventory.json")"
    else
      aliyun_cmd fc CreateTrigger \
        --functionName "${FC_DOMAIN_INVENTORY_FUNCTION_NAME}" \
        --body "$(cat "${RENDERED_DIR}/fc/trigger.timer.domain_inventory.json")"
    fi
  fi
}

stage_invoke() {
  echo "[invoke] domain_inventory"
  aliyun_cmd fc InvokeFunction \
    --functionName "${FC_DOMAIN_INVENTORY_FUNCTION_NAME}" \
    --body "{}"

  echo "[invoke] ssl_checker"
  aliyun_cmd fc InvokeFunction \
    --functionName "${FC_SSL_CHECKER_FUNCTION_NAME}" \
    --body "{}"
}

stage_sls() {
  validate_log_binding
  require_env SLS_SOURCE_LOGSTORE_TTL_DAYS
  require_env SLS_SOURCE_LOGSTORE_SHARD_COUNT
  require_env SLS_TARGET_LOGSTORE_TTL_DAYS
  require_env SLS_TARGET_LOGSTORE_SHARD_COUNT
  validate_uint_env SLS_SOURCE_LOGSTORE_TTL_DAYS
  validate_uint_env SLS_SOURCE_LOGSTORE_SHARD_COUNT
  validate_uint_env SLS_TARGET_LOGSTORE_TTL_DAYS
  validate_uint_env SLS_TARGET_LOGSTORE_SHARD_COUNT

  echo "[sls] ensure fc log resources"
  ensure_sls_project_exists "${FC_LOG_PROJECT}" "${RENDERED_DIR}/sls/project.create.json"
  ensure_sls_logstore_exists "${FC_LOG_PROJECT}" "${FC_LOG_LOGSTORE}" "${RENDERED_DIR}/sls/logstore.source.create.json"
  ensure_sls_index_exists "${FC_LOG_PROJECT}" "${FC_LOG_LOGSTORE}" "${RENDERED_DIR}/sls/logstore.source.index.json"

  echo "[sls] ensure alert resources"
  ensure_sls_logstore_exists "${SLS_PROJECT}" "${SLS_TARGET_LOGSTORE}" "${RENDERED_DIR}/sls/logstore.target.create.json"
  ensure_sls_index_exists "${SLS_PROJECT}" "${SLS_TARGET_LOGSTORE}" "${RENDERED_DIR}/sls/logstore.target.index.json"
}

build_etl_payload() {
  local src="${RENDERED_DIR}/sls/etl.create.json"
  local out="${RENDERED_DIR}/sls/etl.create.final.json"
  local script_text
  script_text="$(cat "${RENDERED_DIR}/sls/etl.rewrite.spl")"
  jq --arg script_text "${script_text}" \
    '.configuration.script = $script_text' \
    "${src}" >"${out}"
}

get_etl_status() {
  local etl_json
  if ! etl_json="$(aliyun_cmd sls GetETL --project "${SLS_PROJECT}" --etlName "${SLS_ETL_NAME}" 2>/dev/null)"; then
    return 1
  fi
  echo "${etl_json}" | jq -r '.status // ""'
}

wait_for_etl_idle() {
  local status=""
  local attempt
  for attempt in $(seq 1 24); do
    status="$(get_etl_status || true)"
    case "${status}" in
      ""|RUNNING|STOPPED|FAILED|SUCCESS)
        [[ -n "${status}" ]] && echo "[etl] current status: ${status}"
        return 0
        ;;
      STARTING|STOPPING|UPDATING|CREATING|RESTARTING)
        echo "[etl] current status: ${status}, waiting..."
        sleep 5
        ;;
      *)
        echo "[etl] current status: ${status}"
        return 0
        ;;
    esac
  done

  echo "[etl] timed out waiting for ETL to become idle. last status: ${status}"
  return 1
}

start_etl_if_needed() {
  local status
  status="$(get_etl_status || true)"
  case "${status}" in
    RUNNING|STARTING|RESTARTING|UPDATING|CREATING|STOPPING)
      echo "[etl] skip start, status is ${status}"
      ;;
    STOPPED|FAILED|SUCCESS|"")
      aliyun_cmd sls StartETL --project "${SLS_PROJECT}" --etlName "${SLS_ETL_NAME}"
      ;;
    *)
      echo "[etl] skip start, unexpected status is ${status}"
      ;;
  esac
}

stage_etl() {
  echo "[etl] preflight sls resources"
  stage_sls

  build_etl_payload
  local etl_source_logstore
  local etl_target_logstore
  etl_source_logstore="$(jq -r '.configuration.logstore' "${RENDERED_DIR}/sls/etl.create.final.json")"
  etl_target_logstore="$(jq -r '.configuration.sinks[0].logstore' "${RENDERED_DIR}/sls/etl.create.final.json")"
  echo "[etl] payload source logstore: ${etl_source_logstore}"
  echo "[etl] payload target logstore: ${etl_target_logstore}"

  echo "[etl] ensure etl task: ${SLS_ETL_NAME}"
  if aliyun_cmd sls GetETL --project "${SLS_PROJECT}" --etlName "${SLS_ETL_NAME}" >/dev/null 2>&1; then
    wait_for_etl_idle
    aliyun_cmd sls UpdateETL \
      --project "${SLS_PROJECT}" \
      --etlName "${SLS_ETL_NAME}" \
      --body "$(json_body "${RENDERED_DIR}/sls/etl.create.final.json")"
  else
    aliyun_cmd sls CreateETL \
      --project "${SLS_PROJECT}" \
      --body "$(json_body "${RENDERED_DIR}/sls/etl.create.final.json")"
  fi

  wait_for_etl_idle
  start_etl_if_needed
}

build_alert_payload() {
  local content_template_id="$1"
  local action_policy_id="$2"
  local src="${RENDERED_DIR}/sls/alert.create.json"
  local out="${RENDERED_DIR}/sls/alert.create.final.json"
  local query_text
  query_text="$(cat "${RENDERED_DIR}/sls/alert.query.sql")"
  if [[ -z "${query_text}" ]]; then
    echo "alert query is empty: ${RENDERED_DIR}/sls/alert.query.sql"
    exit 1
  fi
  jq \
    --arg query_text "${query_text}" \
    --arg content_template_id "${content_template_id}" \
    --arg action_policy_id "${action_policy_id}" \
    '.configuration.queryList[0].query = $query_text
    | .configuration.templateConfiguration.id = $content_template_id
    | .configuration.policyConfiguration.actionPolicyId = $action_policy_id
    | .configuration.dashboard = (if (.configuration.dashboard // "") == "" then "internal-alert-analysis" else .configuration.dashboard end)
    | .configuration.queryList[0].timeSpanType = (if (.configuration.queryList[0].timeSpanType // "") == "" then "Truncated" else .configuration.queryList[0].timeSpanType end)
    | .configuration.queryList[0].start = (if (.configuration.queryList[0].start // "") == "" then "-1d" else .configuration.queryList[0].start end)
    | .configuration.queryList[0].end = (if (.configuration.queryList[0].end // "") == "" then "absolute" else .configuration.queryList[0].end end)
    | if .configuration.queryList[0].timeSpanType == "Relative" and .configuration.queryList[0].end == "now"
      then .configuration.queryList[0].timeSpanType = "Truncated" | .configuration.queryList[0].end = "absolute"
      else .
      end
    | .schedule.interval = (if (.schedule.interval // "") == "" then "1d" else .schedule.interval end)' \
    "${src}" >"${out}"

  if ! jq -e '.configuration.queryList[0].query != "__ALERT_QUERY_PLACEHOLDER__"' "${out}" >/dev/null; then
    echo "alert query placeholder not replaced in payload: ${out}"
    exit 1
  fi

  if ! jq -e '.configuration.queryList[0].query | length > 0' "${out}" >/dev/null; then
    echo "alert query is missing in payload: ${out}"
    exit 1
  fi
}

print_alert_payload_summary() {
  local payload_file="$1"
  echo "[alert] payload dashboard:$(jq -r '.configuration.dashboard // ""' "${payload_file}")"
  echo "[alert] payload project: $(jq -r '.configuration.queryList[0].project' "${payload_file}")"
  echo "[alert] payload store:   $(jq -r '.configuration.queryList[0].store' "${payload_file}")"
  echo "[alert] payload query:   $(jq -r '.configuration.queryList[0].query' "${payload_file}")"
  echo "[alert] payload span:    $(jq -r '.configuration.queryList[0].timeSpanType // ""' "${payload_file}")"
  echo "[alert] payload start:   $(jq -r '.configuration.queryList[0].start // ""' "${payload_file}")"
  echo "[alert] payload end:     $(jq -r '.configuration.queryList[0].end // ""' "${payload_file}")"
  echo "[alert] payload interval:$(jq -r '.schedule.interval' "${payload_file}")"
}

print_alert_query_data_preview() {
  local now_ts
  local from_ts
  now_ts="$(python3 - <<'PY'
import time
print(int(time.time()))
PY
)"
  from_ts="$((now_ts - 86400))"
  local preview_query='* | where status = "expiring" | select count(1) as expiring_count'
  local preview
  if preview="$(aliyun_cmd sls GetLogs \
    --project "${SLS_PROJECT}" \
    --logstore "${SLS_TARGET_LOGSTORE}" \
    --from "${from_ts}" \
    --to "${now_ts}" \
    --query "${preview_query}" \
    --line 1 2>/dev/null)"; then
    echo "[alert] preview(last 1d) query: ${preview_query}"
    echo "[alert] preview(last 1d) result: ${preview}"
  else
    echo "[alert] preview query failed (non-blocking)."
  fi
}

enable_alert_idempotent() {
  local output
  if output="$(aliyun_cmd sls EnableAlert --project "${SLS_PROJECT}" --alertName "${SLS_ALERT_NAME}" 2>&1)"; then
    echo "[alert] enabled: ${SLS_ALERT_NAME}"
    return 0
  fi

  if echo "${output}" | grep -q "The job to enable has already enabled"; then
    echo "[alert] already enabled: ${SLS_ALERT_NAME}"
    return 0
  fi

  echo "${output}"
  return 1
}

bootstrap_alert_resources() {
  echo "[alert] bootstrap content template and action policy" >&2
  python3 "${SCRIPT_DIR}/bootstrap_alert_resources.py" \
    --content-file "${RENDERED_DIR}/sls/notification.content.md" \
    --action-file "${RENDERED_DIR}/sls/action.policy.dsl"
}

stage_alert() {
  local bootstrap_json
  local content_template_id
  local action_policy_id
  local persisted_query
  local persisted_store

  echo "[alert] preflight sls resources"
  stage_sls

  bootstrap_json="$(bootstrap_alert_resources)"
  content_template_id="$(echo "${bootstrap_json}" | jq -r '.content_template_id')"
  action_policy_id="$(echo "${bootstrap_json}" | jq -r '.action_policy_id')"
  if [[ -z "${content_template_id}" || "${content_template_id}" == "null" ]]; then
    echo "failed to resolve content_template_id from bootstrap output"
    echo "${bootstrap_json}"
    exit 1
  fi
  if [[ -z "${action_policy_id}" || "${action_policy_id}" == "null" ]]; then
    echo "failed to resolve action_policy_id from bootstrap output"
    echo "${bootstrap_json}"
    exit 1
  fi
  echo "[alert] resolved content_template_id: ${content_template_id}"
  echo "[alert] resolved action_policy_id: ${action_policy_id}"

  build_alert_payload "${content_template_id}" "${action_policy_id}"
  print_alert_payload_summary "${RENDERED_DIR}/sls/alert.create.final.json"
  echo "[alert] ensure alert: ${SLS_ALERT_NAME}"
  if aliyun_cmd sls GetAlert --project "${SLS_PROJECT}" --alertName "${SLS_ALERT_NAME}" >/dev/null 2>&1; then
    aliyun_cmd sls UpdateAlert \
      --project "${SLS_PROJECT}" \
      --alertName "${SLS_ALERT_NAME}" \
      --body "$(json_body "${RENDERED_DIR}/sls/alert.create.final.json")"
  else
    aliyun_cmd sls CreateAlert \
      --project "${SLS_PROJECT}" \
      --body "$(json_body "${RENDERED_DIR}/sls/alert.create.final.json")"
  fi

  enable_alert_idempotent

  local alert_json
  alert_json="$(aliyun_cmd sls GetAlert --project "${SLS_PROJECT}" --alertName "${SLS_ALERT_NAME}")"
  persisted_store="$(echo "${alert_json}" | jq -r '.configuration.queryList[0].store // ""')"
  persisted_query="$(echo "${alert_json}" | jq -r '.configuration.queryList[0].query // ""')"
  echo "[alert] persisted project: $(echo "${alert_json}" | jq -r '.configuration.queryList[0].project // ""')"
  echo "[alert] persisted store:   ${persisted_store}"
  echo "[alert] persisted query:   ${persisted_query}"
  echo "[alert] persisted span:    $(echo "${alert_json}" | jq -r '.configuration.queryList[0].timeSpanType // ""')"
  echo "[alert] persisted start:   $(echo "${alert_json}" | jq -r '.configuration.queryList[0].start // ""')"
  echo "[alert] persisted end:     $(echo "${alert_json}" | jq -r '.configuration.queryList[0].end // ""')"
  echo "[alert] persisted status:  $(echo "${alert_json}" | jq -r '.status // "Enabled"')"
  if [[ -z "${persisted_store}" || -z "${persisted_query}" ]]; then
    echo "[alert] persisted alert is missing query/store; please inspect:"
    echo "${alert_json}" | jq .
    exit 1
  fi
  print_alert_query_data_preview
}

main() {
  if [[ "${ACTION}" == "-h" || "${ACTION}" == "--help" || "${ACTION}" == "help" ]]; then
    usage
    exit 0
  fi

  require_cmd aliyun
  require_cmd jq
  require_cmd envsubst
  load_env

  case "${ACTION}" in
    render)
      render_all
      ;;
    ram)
      render_all
      stage_ram
      ;;
    fc)
      render_all
      stage_fc
      ;;
    invoke)
      stage_invoke
      ;;
    sls)
      render_all
      stage_sls
      ;;
    etl)
      render_all
      stage_etl
      ;;
    alert)
      render_all
      stage_alert
      ;;
    verify)
      "${SCRIPT_DIR}/verify_steps.sh" all
      ;;
    all)
      render_all
      stage_ram
      stage_sls
      stage_fc
      stage_invoke
      stage_etl
      stage_alert
      ;;
    *)
      echo "unknown action: ${ACTION}"
      usage
      exit 1
      ;;
  esac
}

main "$@"
