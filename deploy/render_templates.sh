#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
RENDER_DIR="${SCRIPT_DIR}/rendered"
VARS_FILE="${1:-${SCRIPT_DIR}/vars.env}"

if [[ ! -f "${VARS_FILE}" ]]; then
  echo "vars file not found: ${VARS_FILE}"
  echo "copy deploy/templates/vars.env.tpl to deploy/vars.env and fill values first."
  exit 1
fi

if ! command -v envsubst >/dev/null 2>&1; then
  echo "envsubst not found. Install gettext first."
  exit 1
fi

set -a
# shellcheck source=/dev/null
source "${VARS_FILE}"
set +a

rm -rf "${RENDER_DIR}"
mkdir -p "${RENDER_DIR}"

while IFS= read -r -d '' tpl; do
  rel_path="${tpl#${TEMPLATE_DIR}/}"
  out_path="${RENDER_DIR}/${rel_path%.tpl}"
  mkdir -p "$(dirname "${out_path}")"
  envsubst <"${tpl}" >"${out_path}"
done < <(find "${TEMPLATE_DIR}" -type f -name "*.tpl" -print0 | sort -z)

echo "rendered templates to: ${RENDER_DIR}"
