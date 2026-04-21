#!/bin/bash

set -euxo pipefail

: "${NAMESPACE:?NAMESPACE is required}"
: "${RESOURCE_GROUP_NAME:?RESOURCE_GROUP_NAME is required}"
: "${SERVICES_ROOT:?SERVICES_ROOT is required}"

WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-900}"
WAIT_INTERVAL_SECONDS="${WAIT_INTERVAL_SECONDS:-5}"

lower_resource_group_name="$(echo "${RESOURCE_GROUP_NAME}" | tr '[:upper:]' '[:lower:]')"

wait_for_identity_client_id() {
  local identity_name="$1"
  local elapsed=0
  local client_id=""

  echo "Waiting for ASO clientId on ${identity_name} in namespace ${NAMESPACE}"

  while [[ "${elapsed}" -lt "${WAIT_TIMEOUT_SECONDS}" ]]; do
    client_id="$(kubectl get userassignedidentity.managedidentity.azure.com "${identity_name}" --namespace "${NAMESPACE}" --output jsonpath='{.status.clientId}' 2>/dev/null || true)"
    if [[ -n "${client_id}" ]]; then
      echo "ASO clientId resolved for ${identity_name}"
      return 0
    fi

    sleep "${WAIT_INTERVAL_SECONDS}"
    elapsed=$((elapsed + WAIT_INTERVAL_SECONDS))
  done

  echo "Timed out waiting for ASO clientId on ${identity_name}" >&2
  kubectl get userassignedidentity.managedidentity.azure.com "${identity_name}" --namespace "${NAMESPACE}" --output yaml || true
  return 1
}

service_has_migrations_enabled() {
  local service_name="$1"
  local base_file="${SERVICES_ROOT}/${service_name}/base.yaml"

  if [[ ! -f "${base_file}" ]]; then
    return 1
  fi

  if command -v yq >/dev/null 2>&1; then
    [[ "$(yq e '.database.migrations.enabled // false' "${base_file}")" == "true" ]]
    return
  fi

  [[ "$(awk '
    $1=="database:" { in_database=1; next }
    in_database && $1=="migrations:" { in_migrations=1; next }
    in_migrations && $1=="enabled:" { print tolower($2); exit }
  ' "${base_file}")" == "true" ]]
}

shopt -s nullglob
service_dirs=("${SERVICES_ROOT}"/*)
shopt -u nullglob

if [[ ${#service_dirs[@]} -eq 0 ]]; then
  echo "No service folders found under ${SERVICES_ROOT}" >&2
  exit 1
fi

for service_dir in "${service_dirs[@]}"; do
  [[ -d "${service_dir}" ]] || continue

  service_name="$(basename "${service_dir}")"
  service_identity_name="${lower_resource_group_name}-${NAMESPACE}-${service_name}-service"
  wait_for_identity_client_id "${service_identity_name}"

  if service_has_migrations_enabled "${service_name}"; then
    migrations_identity_name="${lower_resource_group_name}-${NAMESPACE}-${service_name}-migrations"
    wait_for_identity_client_id "${migrations_identity_name}"
  fi
done

# vim: set ts=2 sts=2 sw=2 et:
