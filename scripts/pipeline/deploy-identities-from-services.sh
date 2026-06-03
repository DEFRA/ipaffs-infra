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

VERIFY_GROUP_MEMBERSHIPS="${VERIFY_GROUP_MEMBERSHIPS:-false}"
lower_resource_group_name="$(echo "${RESOURCE_GROUP_NAME}" | tr '[:upper:]' '[:lower:]')"
search_contributor_principal_ids=()
blob_storage_contributor_principal_ids=()
sql_admin_principal_ids=()
managed_identity_limit=800

add_unique_principal_id() {
  local -n principal_ids="$1"
  local principal_id="$2"
  local existing_principal_id

  for existing_principal_id in "${principal_ids[@]}"; do
    [[ "${existing_principal_id}" == "${principal_id}" ]] && return
  done

  principal_ids+=("${principal_id}")
}

bulk_add_group_members() {
  local group_id="$1"
  local principal_ids="$2"
  local description="$3"

  if [[ -z "${principal_ids}" ]]; then
    echo "No principals to add to ${description}"
    return
  fi

  echo "Adding principals to ${description}"
  GROUP_ID="${group_id}" \
  GROUP_MEMBERS="${principal_ids}" \
  "${SCRIPT_DIR}/add-entra-group-members.sh"
}

wait_for_group_members() {
  local group_id="$1"
  local principal_ids="$2"
  local description="$3"

  if [[ -z "${principal_ids}" ]]; then
    echo "No principals to verify in ${description}"
    return
  fi

  echo "Verifying principals in ${description}"
  GROUP_ID="${group_id}" \
  PRINCIPAL_IDS="${principal_ids}" \
  "${SCRIPT_DIR}/wait-for-group-memberships.sh"
}

identity_name_for() {
  local service_name="$1"
  local role_suffix="$2"

  echo "${lower_resource_group_name}-${NAMESPACE}-${service_name}-${role_suffix}"
}

ensure_identity() {
  local service_name="$1"
  local role_suffix="$2"
  local aks_credential="$3"
  local aks_subject="$4"
  local add_sql_group="$5"
  local managed_identity_name
  local identity_output_file=""
  local principal_id=""

  managed_identity_name="$(identity_name_for "${service_name}" "${role_suffix}")"

  export MANAGED_IDENTITY_NAME="${managed_identity_name}"
  export AKS_CREDENTIAL="${aks_credential}"
  export AKS_AUDIENCES="api://AzureADTokenExchange"
  export AKS_SUBJECT="${aks_subject}"

  identity_output_file="$(mktemp)"
  export CREATE_IDENTITY_OUTPUT_FILE="${identity_output_file}"
  "${SCRIPT_DIR}/create-identity.sh"
  unset CREATE_IDENTITY_OUTPUT_FILE

  # shellcheck disable=SC1090
  source "${identity_output_file}"
  rm -f "${identity_output_file}"
  principal_id="${PRINCIPAL_ID}"

  add_unique_principal_id search_contributor_principal_ids "${principal_id}"
  add_unique_principal_id blob_storage_contributor_principal_ids "${principal_id}"

  if [[ "${add_sql_group}" == "true" ]]; then
    add_unique_principal_id sql_admin_principal_ids "${principal_id}"
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

preflight_identity_quota() {
  local identity_list_json
  local current_count
  local missing_count=0
  local service_dir
  local service_name
  local identity_name
  local projected_count

  echo "Checking managed identity quota for ${RESOURCE_GROUP_NAME}"

  identity_list_json="$(az identity list --subscription "${SUBSCRIPTION_NAME}" --resource-group "${RESOURCE_GROUP_NAME}" -o json)"
  current_count="$(jq 'length' <<<"${identity_list_json}")"

  declare -A existing_identity_names=()
  while IFS= read -r identity_name; do
    [[ -n "${identity_name}" ]] && existing_identity_names["${identity_name}"]=1
  done < <(jq -r '.[].name' <<<"${identity_list_json}")

  for service_dir in "${service_dirs[@]}"; do
    [[ -d "${service_dir}" ]] || continue

    service_name="$(basename "${service_dir}")"
    identity_name="$(identity_name_for "${service_name}" "service")"
    [[ -z "${existing_identity_names[${identity_name}]+x}" ]] && missing_count=$((missing_count + 1))

    if service_has_migrations_enabled "${service_name}"; then
      identity_name="$(identity_name_for "${service_name}" "migrations")"
      [[ -z "${existing_identity_names[${identity_name}]+x}" ]] && missing_count=$((missing_count + 1))
    fi
  done

  projected_count=$((current_count + missing_count))
  echo "Managed identities in resource group: ${current_count}; missing for namespace '${NAMESPACE}': ${missing_count}; projected count: ${projected_count}/${managed_identity_limit}"

  if (( projected_count > managed_identity_limit )); then
    echo "Creating identities for namespace '${NAMESPACE}' would exceed the managed identity quota for resource group '${RESOURCE_GROUP_NAME}'." >&2
    echo "Delete unused branch namespace identities first, for example with scripts/pipeline/delete-namespace-identities.sh, or reuse an existing namespace." >&2
    exit 1
  fi
}

shopt -s nullglob
service_dirs=("${SERVICES_ROOT}"/*)
shopt -u nullglob

if [[ ${#service_dirs[@]} -eq 0 ]]; then
  echo "No service folders found under ${SERVICES_ROOT}"
  exit 1
fi

preflight_identity_quota

for service_dir in "${service_dirs[@]}"; do
  [[ -d "${service_dir}" ]] || continue

  service_name="$(basename "${service_dir}")"
  echo "Configuring identities for ${service_name}"

  ensure_identity "${service_name}" "service" "${service_name}-service" "system:serviceaccount:${NAMESPACE}:${service_name}-service" "true"

  if service_has_migrations_enabled "${service_name}"; then
    ensure_identity "${service_name}" "migrations" "${service_name}-migration" "system:serviceaccount:${NAMESPACE}:${service_name}-migrations" "true"
  else
    echo "Skipping migrations identity for ${service_name} because database.migrations.enabled is not true"
  fi
done

search_contributor_principals="${search_contributor_principal_ids[*]}"
blob_storage_contributor_principals="${blob_storage_contributor_principal_ids[*]}"
sql_admin_principals="${sql_admin_principal_ids[*]}"

bulk_add_group_members "${SEARCH_CONTRIBUTORS_GROUP_ID}" "${search_contributor_principals}" "search contributors group"
bulk_add_group_members "${BLOB_STORAGE_CONTRIBUTORS_GROUP_ID}" "${blob_storage_contributor_principals}" "blob storage contributors group"
bulk_add_group_members "${SQL_ADMIN_GROUP_ID}" "${sql_admin_principals}" "SQL admins group"

if [[ "${VERIFY_GROUP_MEMBERSHIPS}" == "true" ]]; then
  wait_for_group_members "${SEARCH_CONTRIBUTORS_GROUP_ID}" "${search_contributor_principals}" "search contributors group"
  wait_for_group_members "${BLOB_STORAGE_CONTRIBUTORS_GROUP_ID}" "${blob_storage_contributor_principals}" "blob storage contributors group"
  wait_for_group_members "${SQL_ADMIN_GROUP_ID}" "${sql_admin_principals}" "SQL admins group"
else
  echo "Skipping group membership verification because VERIFY_GROUP_MEMBERSHIPS is not true"
fi

# vim: set ts=2 sts=2 sw=2 et:
