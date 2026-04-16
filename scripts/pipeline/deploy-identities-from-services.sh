#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${NAMESPACE:?NAMESPACE is required}"
: "${RESOURCE_GROUP_NAME:?RESOURCE_GROUP_NAME is required}"
: "${AKS_ISSUER:?AKS_ISSUER is required}"
: "${SEARCH_CONTRIBUTORS_GROUP_ID:?SEARCH_CONTRIBUTORS_GROUP_ID is required}"
: "${BLOB_STORAGE_CONTRIBUTORS_GROUP_ID:?BLOB_STORAGE_CONTRIBUTORS_GROUP_ID is required}"
: "${SQL_ADMIN_GROUP_ID:?SQL_ADMIN_GROUP_ID is required}"
: "${SERVICES_ROOT:?SERVICES_ROOT is required}"

lower_resource_group_name="$(echo "${RESOURCE_GROUP_NAME}" | tr '[:upper:]' '[:lower:]')"
wait_pids=()
wait_descriptions=()

queue_group_membership_wait() {
  local group_id="$1"
  local principal_id="$2"
  local description="$3"

  (
    GROUP_ID="${group_id}" \
    PRINCIPAL_ID="${principal_id}" \
    "${SCRIPT_DIR}/wait-for-group-membership.sh"
  ) &

  wait_pids+=("$!")
  wait_descriptions+=("${description}")
}

wait_for_all_group_memberships() {
  local failures=0
  local idx=0

  if [[ ${#wait_pids[@]} -eq 0 ]]; then
    return
  fi

  echo "Waiting for ${#wait_pids[@]} group membership checks to complete"

  for idx in "${!wait_pids[@]}"; do
    if wait "${wait_pids[$idx]}"; then
      echo "Group membership ready: ${wait_descriptions[$idx]}"
    else
      echo "Group membership check failed: ${wait_descriptions[$idx]}" >&2
      failures=$((failures + 1))
    fi
  done

  if [[ ${failures} -gt 0 ]]; then
    echo "${failures} group membership checks failed" >&2
    exit 1
  fi
}

ensure_identity() {
  local service_name="$1"
  local role_suffix="$2"
  local aks_credential="$3"
  local aks_subject="$4"
  local add_sql_group="$5"
  local managed_identity_name="${lower_resource_group_name}-${NAMESPACE}-${service_name}-${role_suffix}"
  local principal_id=""

  export MANAGED_IDENTITY_NAME="${managed_identity_name}"
  export AKS_CREDENTIAL="${aks_credential}"
  export AKS_AUDIENCES="api://AzureADTokenExchange"
  export AKS_SUBJECT="${aks_subject}"

  "${SCRIPT_DIR}/create-identity.sh"

  principal_id="$(az identity show --subscription "${SUBSCRIPTION_NAME}" --name "${managed_identity_name}" --resource-group "${RESOURCE_GROUP_NAME}" --query principalId -o tsv)"

  export GROUP_ID="${SEARCH_CONTRIBUTORS_GROUP_ID}"
  export PRINCIPAL_ID="${principal_id}"
  "${SCRIPT_DIR}/add-principal-to-group.sh"
  queue_group_membership_wait "${SEARCH_CONTRIBUTORS_GROUP_ID}" "${principal_id}" "${managed_identity_name} in search contributors"

  export GROUP_ID="${BLOB_STORAGE_CONTRIBUTORS_GROUP_ID}"
  "${SCRIPT_DIR}/add-principal-to-group.sh"
  queue_group_membership_wait "${BLOB_STORAGE_CONTRIBUTORS_GROUP_ID}" "${principal_id}" "${managed_identity_name} in blob storage contributors"

  if [[ "${add_sql_group}" == "true" ]]; then
    export GROUP_ID="${SQL_ADMIN_GROUP_ID}"
    "${SCRIPT_DIR}/add-principal-to-group.sh"
    queue_group_membership_wait "${SQL_ADMIN_GROUP_ID}" "${principal_id}" "${managed_identity_name} in sql admins"
  fi
}

service_has_migrations_enabled() {
  local service_name="$1"
  local base_file="${SERVICES_ROOT}/${service_name}/base.yaml"

  if [[ -n "${MIGRATIONS_ENABLED_SERVICES:-}" ]]; then
    case ",${MIGRATIONS_ENABLED_SERVICES}," in
      *",${service_name},"*) return 0 ;;
      *) return 1 ;;
    esac
  fi

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
  echo "No service folders found under ${SERVICES_ROOT}"
  exit 1
fi

for service_dir in "${service_dirs[@]}"; do
  [[ -d "${service_dir}" ]] || continue

  service_name="$(basename "${service_dir}")"
  echo "Configuring identities for ${service_name}"

  ensure_identity "${service_name}" "service" "${service_name}-service" "system:serviceaccount:${NAMESPACE}:${service_name}-service" "false"

  if service_has_migrations_enabled "${service_name}"; then
    ensure_identity "${service_name}" "migrations" "${service_name}-migration" "system:serviceaccount:${NAMESPACE}:${service_name}-migrations" "true"
  else
    echo "Skipping migrations identity for ${service_name} because database.migrations.enabled is not true"
  fi
done

wait_for_all_group_memberships

# vim: set ts=2 sts=2 sw=2 et:
