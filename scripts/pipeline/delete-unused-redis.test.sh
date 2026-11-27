#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="${script_dir}/../hooks/30-delete-unused-redis.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT
export PATH="${test_dir}:${PATH}"
export AZ_CALLS="${test_dir}/az-calls"
export CACHE_PRESENT="${test_dir}/cache-present"
export ENDPOINT_PRESENT="${test_dir}/endpoint-present"

cat > "${test_dir}/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
expected_scope() {
  tr '[:upper:]' '[:lower:]' <<<"$1"
}

[[ "$1" == resource && "$3" == --ids ]] || exit 99
action="$2"
id="$4"
shift 4
if [[ "$(expected_scope "${id}")" == "$(expected_scope "${CACHE_ID}")" ]]; then
  target=cache
  present="${CACHE_PRESENT}"
elif [[ "$(expected_scope "${id}")" == "$(expected_scope "${ENDPOINT_ID}")" ]]; then
  target=endpoint
  present="${ENDPOINT_PRESENT}"
else
  echo "Unexpected resource ID: ${id}" >&2
  exit 99
fi

printf '%s %s\n' "${action}" "${target}" >> "${AZ_CALLS}"
[[ " $* " == *" --subscription ${EXPECTED_SUBSCRIPTION} "* ]] || exit 99
case "${action}-${target}-${SCENARIO}" in
  show-endpoint-forbidden|delete-cache-delete-denied)
    echo "Code: AuthorizationFailed" >&2
    exit 1
    ;;
esac

if [[ ! -f "${present}" ]]; then
  echo "ERROR: (ResourceNotFound) The resource was not found." >&2
  exit 3
fi

case "${action}-${target}" in
  show-cache)
    endpoints='[]'
    if [[ -f "${ENDPOINT_PRESENT}" ]]; then
      endpoint="${ENDPOINT_ID}"
      if [[ "${SCENARIO}" == foreign-endpoint ]]; then
        endpoint="${endpoint}-other"
      fi
      endpoints="[{\"properties\":{\"privateEndpoint\":{\"id\":\"${endpoint}\"}}}]"
    fi
    printf '{"id":"%s","endpoints":%s}\n' "${CACHE_ID}" "${endpoints}"
    ;;
  show-endpoint)
    cache="${CACHE_ID}"
    if [[ "${SCENARIO}" == foreign-cache ]]; then
      cache="${cache}-other"
    fi
    printf '{"id":"%s","connections":[{"properties":{"privateLinkServiceId":"%s"}}],"manualConnections":[]}\n' \
      "${ENDPOINT_ID}" "${cache}"
    ;;
  delete-*)
    rm "${present}"
    ;;
  *)
    exit 99
    ;;
esac
EOF
chmod +x "${test_dir}/az"

select_target() {
  local environment="$1" upper="$2"
  export EXPECTED_SUBSCRIPTION="$3"
  group="${upper}IMPINFRG1401"
  local base="/subscriptions/${EXPECTED_SUBSCRIPTION}/resourceGroups/${group}/providers"
  local name="${environment}impinfrd1401"
  export CACHE_ID="${base}/Microsoft.Cache/redis/${name}"
  export ENDPOINT_ID="${base}/Microsoft.Network/privateEndpoints/${name}-${upper}IMPNETSU4404"
}

run_hook() {
  local environment="$1" dry_run="$2" scenario="${3:-}"
  local subscription="${4-${EXPECTED_SUBSCRIPTION}}" resource_group="${5-${group}}"
  : > "${AZ_CALLS}"
  ENVIRONMENT="${environment}" DRY_RUN="${dry_run}" SCENARIO="${scenario}" \
    SUBSCRIPTION_ID="${subscription}" RESOURCE_GROUP_NAME="${resource_group}" bash "${hook}"
}

expect_failure() {
  local diagnostic="$1" output
  shift
  if output="$(run_hook "$@" 2>&1)" || [[ "${output}" != *"${diagnostic}"* ]]; then
    printf 'Expected failure containing %s\n%s\n' "${diagnostic}" "${output}" >&2
    exit 1
  fi
}

expect_calls() {
  local actual
  actual="$(cat "${AZ_CALLS}")"
  if [[ "${actual}" != "$1" ]]; then
    printf 'Expected Azure calls:\n%s\nActual:\n%s\n' "$1" "${actual}" >&2
    exit 1
  fi
}

lookups=$'show cache\nshow endpoint'
select_target tst TST '0022ef8e-d44e-49c5-8cfd-5e8e9c6e913e'
touch "${CACHE_PRESENT}" "${ENDPOINT_PRESENT}"

run_hook dev false '' '' ''
expect_calls ''
expect_failure 'subscription or resource group' tst false '' '3978eb4f-add1-415d-839b-db398e65a7d9'
expect_calls ''
expect_failure 'subscription or resource group' tst false '' "${EXPECTED_SUBSCRIPTION}" 'PREIMPINFRG1401'
expect_calls ''

dry_run_output="$(run_hook tst '')"
[[ "${dry_run_output}" == *"Would delete"* && -f "${CACHE_PRESENT}" && -f "${ENDPOINT_PRESENT}" ]]
expect_calls "${lookups}"

expect_failure 'AuthorizationFailed' tst false forbidden
expect_calls "${lookups}"
expect_failure 'endpoint' tst false foreign-endpoint
[[ "$(cat "${AZ_CALLS}")" != *delete* ]]
expect_failure 'endpoint' tst false foreign-cache
expect_calls "${lookups}"

expect_failure 'AuthorizationFailed' tst false delete-denied
expect_calls "${lookups}"$'\ndelete endpoint\ndelete cache'
[[ -f "${CACHE_PRESENT}" && ! -f "${ENDPOINT_PRESENT}" ]]
run_hook tst false
expect_calls "${lookups}"$'\ndelete cache'

select_target pre PRE '3978eb4f-add1-415d-839b-db398e65a7d9'
touch "${CACHE_PRESENT}" "${ENDPOINT_PRESENT}"
run_hook pre false
expect_calls "${lookups}"$'\ndelete endpoint\ndelete cache'
[[ ! -f "${CACHE_PRESENT}" && ! -f "${ENDPOINT_PRESENT}" ]]
run_hook pre false
expect_calls "${lookups}"

select_target prd PRD '5f38dc6f-69b9-4d1b-9000-7e0b8277e515'
touch "${ENDPOINT_PRESENT}"
run_hook prd false
expect_calls "${lookups}"$'\ndelete endpoint'
[[ ! -f "${ENDPOINT_PRESENT}" ]]

echo "All unused Redis cleanup hook checks passed"
