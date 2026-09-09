#!/bin/bash

set -euo pipefail

: "${NAMESPACE:?NAMESPACE is required}"
: "${RESOURCE_GROUP_NAME:?RESOURCE_GROUP_NAME is required}"
: "${SERVICES_ROOT:?SERVICES_ROOT is required}"

ASO_IDENTITY_WAIT_MODE="${ASO_IDENTITY_WAIT_MODE:-sequential}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-900}"
WAIT_INTERVAL_SECONDS="${WAIT_INTERVAL_SECONDS:-5}"

if ! [[ "${WAIT_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "WAIT_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 1
fi

if ! [[ "${WAIT_INTERVAL_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "WAIT_INTERVAL_SECONDS must be a positive integer" >&2
  exit 1
fi

case "${ASO_IDENTITY_WAIT_MODE}" in
  sequential | batch) ;;
  *)
    echo "ASO_IDENTITY_WAIT_MODE must be 'sequential' or 'batch'" >&2
    exit 1
    ;;
esac

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

wait_for_identity_client_ids_sequentially() {
  local identity_name

  for identity_name in "$@"; do
    wait_for_identity_client_id "${identity_name}"
  done
}

batch_snapshot_file=""
batch_error_file=""
batch_expected_file=""
batch_unresolved_file=""

# Invoked by the EXIT trap below.
# shellcheck disable=SC2329
cleanup_batch_files() {
  local status=$?

  [[ -z "${batch_snapshot_file}" ]] || rm -f -- "${batch_snapshot_file}"
  [[ -z "${batch_error_file}" ]] || rm -f -- "${batch_error_file}"
  [[ -z "${batch_expected_file}" ]] || rm -f -- "${batch_expected_file}"
  [[ -z "${batch_unresolved_file}" ]] || rm -f -- "${batch_unresolved_file}"

  return "${status}"
}

trap cleanup_batch_files EXIT

classify_unresolved_identities() {
  jq --rawfile expected "${batch_expected_file}" --raw-output '
    ($expected | split("\n") | map(select(length > 0))) as $expected_names
    | ([.items[] | (.metadata.name // empty)]) as $present_names
    | ([.items[] | select((.status.clientId // "") != "") | .metadata.name]) as $ready_names
    | $expected_names[]
    | . as $name
    | if (($ready_names | index($name)) != null) then
        empty
      elif (($present_names | index($name)) == null) then
        ["missing", $name] | @tsv
      else
        ["pending", $name] | @tsv
      end
  ' "${batch_snapshot_file}" > "${batch_unresolved_file}"
}

print_unresolved_identities() {
  if grep -q $'^missing\t' "${batch_unresolved_file}"; then
    echo "ASO identity resources not found:" >&2
    awk -F '\t' '$1 == "missing" { print "  - " $2 }' "${batch_unresolved_file}" >&2
  fi

  if grep -q $'^pending\t' "${batch_unresolved_file}"; then
    echo "ASO identity resources without status.clientId:" >&2
    awk -F '\t' '$1 == "pending" { print "  - " $2 }' "${batch_unresolved_file}" >&2
  fi
}

wait_for_identity_client_ids_in_batch() {
  local elapsed=0
  local expected_count="$#"
  local missing_count=0
  local pending_count=0

  batch_snapshot_file="$(mktemp)"
  batch_error_file="$(mktemp)"
  batch_expected_file="$(mktemp)"
  batch_unresolved_file="$(mktemp)"

  printf '%s\n' "$@" > "${batch_expected_file}"
  echo "Waiting for ASO clientIds on ${expected_count} identities in namespace ${NAMESPACE}"

  while [[ "${elapsed}" -lt "${WAIT_TIMEOUT_SECONDS}" ]]; do
    if ! kubectl get userassignedidentity.managedidentity.azure.com \
      --namespace "${NAMESPACE}" \
      --output json \
      > "${batch_snapshot_file}" \
      2> "${batch_error_file}"; then
      echo "Unable to list ASO identity resources; switching to sequential readiness checks" >&2
      sed 's/^/  /' "${batch_error_file}" >&2
      wait_for_identity_client_ids_sequentially "$@"
      return
    fi

    if ! jq --exit-status '.items | type == "array"' "${batch_snapshot_file}" >/dev/null 2>&1; then
      echo "ASO identity list returned an invalid response; switching to sequential readiness checks" >&2
      wait_for_identity_client_ids_sequentially "$@"
      return
    fi

    if ! classify_unresolved_identities; then
      echo "Unable to process the ASO identity list; switching to sequential readiness checks" >&2
      wait_for_identity_client_ids_sequentially "$@"
      return
    fi

    if [[ ! -s "${batch_unresolved_file}" ]]; then
      echo "ASO clientIds resolved for all ${expected_count} identities"
      return 0
    fi

    missing_count="$(awk -F '\t' '$1 == "missing" { count++ } END { print count + 0 }' "${batch_unresolved_file}")"
    pending_count="$(awk -F '\t' '$1 == "pending" { count++ } END { print count + 0 }' "${batch_unresolved_file}")"
    echo "Waiting for ASO clientIds: ${missing_count} resources not found, ${pending_count} clientIds pending"

    sleep "${WAIT_INTERVAL_SECONDS}"
    elapsed=$((elapsed + WAIT_INTERVAL_SECONDS))
  done

  echo "Timed out after ${WAIT_TIMEOUT_SECONDS}s waiting for ASO clientIds in namespace ${NAMESPACE}" >&2
  print_unresolved_identities
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

expected_identity_names=()

for service_dir in "${service_dirs[@]}"; do
  [[ -d "${service_dir}" ]] || continue

  service_name="$(basename "${service_dir}")"
  service_identity_name="${lower_resource_group_name}-${NAMESPACE}-${service_name}-service"
  expected_identity_names+=("${service_identity_name}")

  if service_has_migrations_enabled "${service_name}"; then
    migrations_identity_name="${lower_resource_group_name}-${NAMESPACE}-${service_name}-migrations"
    expected_identity_names+=("${migrations_identity_name}")
  fi
done

if [[ ${#expected_identity_names[@]} -eq 0 ]]; then
  echo "No service folders found under ${SERVICES_ROOT}" >&2
  exit 1
fi

echo "Using ${ASO_IDENTITY_WAIT_MODE} ASO identity readiness checks"

if [[ "${ASO_IDENTITY_WAIT_MODE}" == "batch" ]]; then
  wait_for_identity_client_ids_in_batch "${expected_identity_names[@]}"
else
  wait_for_identity_client_ids_sequentially "${expected_identity_names[@]}"
fi
