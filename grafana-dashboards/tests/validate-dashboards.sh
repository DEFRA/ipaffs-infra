#!/bin/bash
# validate-dashboards.sh
#
# Validates all Grafana dashboard JSON files under DASHBOARDS_DIR recursively.
# Validates all dashboard JSON under grafana-dashboards/dashboards/.
#
# Checks per file:
#   1. Valid JSON
#   2. Required fields: title, uid, schemaVersion, panels
#   3. id is null (required for portable Grafana API import)
#   4. uid is unique across all files in the tree
#
# Usage:
#   bash grafana-dashboards/tests/validate-dashboards.sh
#   DASHBOARDS_DIR=grafana-dashboards/dashboards bash grafana-dashboards/tests/validate-dashboards.sh

set -euo pipefail

DASHBOARDS_DIR="${DASHBOARDS_DIR:-grafana-dashboards/dashboards}"
REQUIRED_FIELDS=("title" "uid" "schemaVersion" "panels")

if [[ ! -d "${DASHBOARDS_DIR}" ]]; then
  echo "ERROR: directory not found: ${DASHBOARDS_DIR}"
  exit 1
fi

mapfile -t dashboard_files < <(find "${DASHBOARDS_DIR}" -name "*.json" | sort)

if [[ ${#dashboard_files[@]} -eq 0 ]]; then
  echo "ERROR: No dashboard JSON files found under ${DASHBOARDS_DIR}"
  exit 1
fi

echo "Validating ${#dashboard_files[@]} dashboard(s) under ${DASHBOARDS_DIR}/"
echo ""

ERRORS=0
declare -A seen_uids

for file in "${dashboard_files[@]}"; do
  echo "-- ${file}"
  file_errors=0

  # 1. Valid JSON
  if ! jq empty "${file}" 2>/dev/null; then
    echo "   FAIL: not valid JSON"
    ERRORS=$((ERRORS + 1))
    echo ""
    continue
  fi

  # 2. Required top-level fields
  for field in "${REQUIRED_FIELDS[@]}"; do
    has_field=$(jq --arg f "${field}" 'has($f)' "${file}")
    if [[ "${has_field}" != "true" ]]; then
      echo "   FAIL: missing required field '${field}'"
      ERRORS=$((ERRORS + 1))
      file_errors=$((file_errors + 1))
    fi
  done

  # 3. id must be null
  id_value=$(jq '.id' "${file}")
  if [[ "${id_value}" != "null" ]]; then
    echo "   FAIL: 'id' must be null (got '${id_value}'). Re-export with export-dashboard.sh."
    ERRORS=$((ERRORS + 1))
    file_errors=$((file_errors + 1))
  fi

  # 4. uid uniqueness
  uid=$(jq -r '.uid // ""' "${file}")
  if [[ -z "${uid}" ]]; then
    echo "   FAIL: 'uid' is missing or empty"
    ERRORS=$((ERRORS + 1))
    file_errors=$((file_errors + 1))
  else
    existing="${seen_uids[${uid}]+set}"
    if [[ -n "${existing}" ]]; then
      echo "   FAIL: duplicate uid '${uid}' (also in ${seen_uids[${uid}]})"
      ERRORS=$((ERRORS + 1))
      file_errors=$((file_errors + 1))
    else
      seen_uids["${uid}"]="${file}"
    fi
  fi

  if [[ "${file_errors}" -eq 0 ]]; then
    echo "   OK  (uid=${uid})"
  fi
  echo ""
done

echo "----------------------------------------"
if [[ "${ERRORS}" -gt 0 ]]; then
  echo "FAILED: ${ERRORS} error(s) across ${#dashboard_files[@]} dashboard(s)."
  exit 1
fi

echo "PASSED: all ${#dashboard_files[@]} dashboard(s) are valid."

# vim: set ts=2 sts=2 sw=2 et:
