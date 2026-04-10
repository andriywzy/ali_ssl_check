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
  fc      Upload code packages, create/update FC service/functions/optional timer trigger
  invoke  Invoke domain_inventory and ssl_checker for smoke validation
  sls     Create target SLS logstore and index
  etl     Create/update and start SLS ETL rewrite task
  alert   Create/update and enable SLS alert
  verify  Verify deployment steps (delegates to ./deploy/verify_steps.sh)
  all     Execute: render -> ram -> fc -> invoke -> sls -> etl -> alert
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

render_all() {
  echo "[render] rendering templates..."
  "${RENDER_SCRIPT}" "${VARS_FILE}"
}

prepare_policy_docs() {
  mkdir -p "${RENDERED_DIR}/policies"
  sed \
    -e "s#<your-bucket>#${OSS_BUCKET}#g" \
    -e "s#<your-prefix>#${OSS_PREFIX}#g" \
    "${ROOT_DIR}/policies/domain-inventory-role-policy.json" \
    >"${RENDERED_DIR}/policies/domain-inventory-role-policy.json"

  sed \
    -e "s#<your-bucket>#${OSS_BUCKET}#g" \
    -e "s#<your-prefix>#${OSS_PREFIX}#g" \
    "${ROOT_DIR}/policies/ssl-checker-role-policy.json" \
    >"${RENDERED_DIR}/policies/ssl-checker-role-policy.json"
}

stage_ram() {
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
  if ! aliyun_cmd ram GetPolicy --PolicyType Custom --PolicyName "${RAM_POLICY_DOMAIN_INVENTORY}" >/dev/null 2>&1; then
    aliyun_cmd ram CreatePolicy \
      --PolicyName "${RAM_POLICY_DOMAIN_INVENTORY}" \
      --Description "domain inventory minimal policy" \
      --PolicyDocument "$(cat "${RENDERED_DIR}/policies/domain-inventory-role-policy.json")"
  fi

  echo "[ram] ensure policy: ${RAM_POLICY_SSL_CHECKER}"
  if ! aliyun_cmd ram GetPolicy --PolicyType Custom --PolicyName "${RAM_POLICY_SSL_CHECKER}" >/dev/null 2>&1; then
    aliyun_cmd ram CreatePolicy \
      --PolicyName "${RAM_POLICY_SSL_CHECKER}" \
      --Description "ssl checker minimal policy" \
      --PolicyDocument "$(cat "${RENDERED_DIR}/policies/ssl-checker-role-policy.json")"
  fi

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
  upload_packages

  echo "[fc] ensure service: ${FC_SERVICE_NAME}"
  if aliyun_cmd fc-open GetService --serviceName "${FC_SERVICE_NAME}" >/dev/null 2>&1; then
    aliyun_cmd fc-open UpdateService \
      --serviceName "${FC_SERVICE_NAME}" \
      --body "$(cat "${RENDERED_DIR}/fc/service.create.json")"
  else
    aliyun_cmd fc-open CreateService \
      --body "$(cat "${RENDERED_DIR}/fc/service.create.json")"
  fi

  echo "[fc] ensure function: ${FC_DOMAIN_INVENTORY_FUNCTION_NAME}"
  if aliyun_cmd fc-open GetFunction --serviceName "${FC_SERVICE_NAME}" --functionName "${FC_DOMAIN_INVENTORY_FUNCTION_NAME}" >/dev/null 2>&1; then
    aliyun_cmd fc-open UpdateFunction \
      --serviceName "${FC_SERVICE_NAME}" \
      --functionName "${FC_DOMAIN_INVENTORY_FUNCTION_NAME}" \
      --functionUpdateFields "$(cat "${RENDERED_DIR}/fc/function.domain_inventory.create.json")"
  else
    aliyun_cmd fc-open CreateFunction \
      --serviceName "${FC_SERVICE_NAME}" \
      --function "$(cat "${RENDERED_DIR}/fc/function.domain_inventory.create.json")"
  fi

  echo "[fc] ensure function: ${FC_SSL_CHECKER_FUNCTION_NAME}"
  if aliyun_cmd fc-open GetFunction --serviceName "${FC_SERVICE_NAME}" --functionName "${FC_SSL_CHECKER_FUNCTION_NAME}" >/dev/null 2>&1; then
    aliyun_cmd fc-open UpdateFunction \
      --serviceName "${FC_SERVICE_NAME}" \
      --functionName "${FC_SSL_CHECKER_FUNCTION_NAME}" \
      --functionUpdateFields "$(cat "${RENDERED_DIR}/fc/function.ssl_checker.create.json")"
  else
    aliyun_cmd fc-open CreateFunction \
      --serviceName "${FC_SERVICE_NAME}" \
      --function "$(cat "${RENDERED_DIR}/fc/function.ssl_checker.create.json")"
  fi

  if [[ "${FC_TRIGGER_TIMER_ENABLED}" == "true" ]]; then
    echo "[fc] ensure timer trigger: ${FC_TRIGGER_TIMER_NAME}"
    if aliyun_cmd fc-open GetTrigger \
      --serviceName "${FC_SERVICE_NAME}" \
      --functionName "${FC_DOMAIN_INVENTORY_FUNCTION_NAME}" \
      --triggerName "${FC_TRIGGER_TIMER_NAME}" >/dev/null 2>&1; then
      aliyun_cmd fc-open UpdateTrigger \
        --serviceName "${FC_SERVICE_NAME}" \
        --functionName "${FC_DOMAIN_INVENTORY_FUNCTION_NAME}" \
        --triggerName "${FC_TRIGGER_TIMER_NAME}" \
        --body "$(cat "${RENDERED_DIR}/fc/trigger.timer.domain_inventory.json")"
    else
      aliyun_cmd fc-open CreateTrigger \
        --serviceName "${FC_SERVICE_NAME}" \
        --functionName "${FC_DOMAIN_INVENTORY_FUNCTION_NAME}" \
        --body "$(cat "${RENDERED_DIR}/fc/trigger.timer.domain_inventory.json")"
    fi
  fi
}

stage_invoke() {
  echo "[invoke] domain_inventory"
  aliyun_cmd fc-open InvokeFunction \
    --serviceName "${FC_SERVICE_NAME}" \
    --functionName "${FC_DOMAIN_INVENTORY_FUNCTION_NAME}" \
    --body "{}"

  echo "[invoke] ssl_checker"
  aliyun_cmd fc-open InvokeFunction \
    --serviceName "${FC_SERVICE_NAME}" \
    --functionName "${FC_SSL_CHECKER_FUNCTION_NAME}" \
    --body "{}"
}

stage_sls() {
  echo "[sls] ensure target logstore: ${SLS_TARGET_LOGSTORE}"
  if ! aliyun_cmd sls GetLogStore --project "${SLS_PROJECT}" --logstore "${SLS_TARGET_LOGSTORE}" >/dev/null 2>&1; then
    aliyun_cmd sls CreateLogStore \
      --project "${SLS_PROJECT}" \
      --body "$(cat "${RENDERED_DIR}/sls/logstore.target.create.json")"
  fi

  echo "[sls] ensure target logstore index"
  if aliyun_cmd sls GetIndex --project "${SLS_PROJECT}" --logstore "${SLS_TARGET_LOGSTORE}" >/dev/null 2>&1; then
    aliyun_cmd sls UpdateIndex \
      --project "${SLS_PROJECT}" \
      --logstore "${SLS_TARGET_LOGSTORE}" \
      --body "$(cat "${RENDERED_DIR}/sls/logstore.target.index.json")"
  else
    aliyun_cmd sls CreateIndex \
      --project "${SLS_PROJECT}" \
      --logstore "${SLS_TARGET_LOGSTORE}" \
      --body "$(cat "${RENDERED_DIR}/sls/logstore.target.index.json")"
  fi
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

stage_etl() {
  build_etl_payload
  echo "[etl] ensure etl task: ${SLS_ETL_NAME}"
  if aliyun_cmd sls GetETL --project "${SLS_PROJECT}" --etlName "${SLS_ETL_NAME}" >/dev/null 2>&1; then
    aliyun_cmd sls UpdateETL \
      --project "${SLS_PROJECT}" \
      --etlName "${SLS_ETL_NAME}" \
      --body "$(cat "${RENDERED_DIR}/sls/etl.create.final.json")"
  else
    aliyun_cmd sls CreateETL \
      --project "${SLS_PROJECT}" \
      --body "$(cat "${RENDERED_DIR}/sls/etl.create.final.json")"
  fi

  aliyun_cmd sls StartETL --project "${SLS_PROJECT}" --etlName "${SLS_ETL_NAME}"
}

build_alert_payload() {
  local src="${RENDERED_DIR}/sls/alert.create.json"
  local out="${RENDERED_DIR}/sls/alert.create.final.json"
  local query_text
  query_text="$(cat "${RENDERED_DIR}/sls/alert.query.sql")"
  jq --arg query_text "${query_text}" \
    '.configuration.queryList[0].query = $query_text' \
    "${src}" >"${out}"
}

stage_alert() {
  build_alert_payload
  echo "[alert] ensure alert: ${SLS_ALERT_NAME}"
  if aliyun_cmd sls GetAlert --project "${SLS_PROJECT}" --alertName "${SLS_ALERT_NAME}" >/dev/null 2>&1; then
    aliyun_cmd sls UpdateAlert \
      --project "${SLS_PROJECT}" \
      --alertName "${SLS_ALERT_NAME}" \
      --body "$(cat "${RENDERED_DIR}/sls/alert.create.final.json")"
  else
    aliyun_cmd sls CreateAlert \
      --project "${SLS_PROJECT}" \
      --body "$(cat "${RENDERED_DIR}/sls/alert.create.final.json")"
  fi

  aliyun_cmd sls EnableAlert --project "${SLS_PROJECT}" --alertName "${SLS_ALERT_NAME}"
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
      stage_fc
      stage_invoke
      stage_sls
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
