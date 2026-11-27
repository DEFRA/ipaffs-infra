#!/usr/bin/env bash
# IMTA-21720: Retire the unused Azure Cache for Redis resources in the new subscriptions.
set -euo pipefail

fail() {
  echo "##vso[task.logissue type=error]$*"
  echo "ERROR: $*" >&2
  exit 1
}

case "${ENVIRONMENT:-}" in
  dev)
    allowed_scope='/subscriptions/f27f4f47-2766-40c8-8450-f585675f76a2/resourceGroups/DEVIMPINFRG1401'
    cache_name='devimpinfrd1401'
    endpoint_name='devimpinfrd1401-DEVIMPNETSU4404'
    ;;
  tst)
    allowed_scope='/subscriptions/0022ef8e-d44e-49c5-8cfd-5e8e9c6e913e/resourceGroups/TSTIMPINFRG1401'
    cache_name='tstimpinfrd1401'
    endpoint_name='tstimpinfrd1401-TSTIMPNETSU4404'
    ;;
  pre)
    allowed_scope='/subscriptions/3978eb4f-add1-415d-839b-db398e65a7d9/resourceGroups/PREIMPINFRG1401'
    cache_name='preimpinfrd1401'
    endpoint_name='preimpinfrd1401-PREIMPNETSU4404'
    ;;
  prd)
    allowed_scope='/subscriptions/5f38dc6f-69b9-4d1b-9000-7e0b8277e515/resourceGroups/PRDIMPINFRG1401'
    cache_name='prdimpinfrd1401'
    endpoint_name='prdimpinfrd1401-PRDIMPNETSU4404'
    ;;
  *) fail "Expected ENVIRONMENT to be dev, tst, pre or prd" ;;
esac

subscription_id="$(tr '[:upper:]' '[:lower:]' <<<"${SUBSCRIPTION_ID:-}")"
resource_group="$(tr '[:lower:]' '[:upper:]' <<<"${RESOURCE_GROUP_NAME:-}")"
[[ "/subscriptions/${subscription_id}/resourceGroups/${resource_group}" == "${allowed_scope}" ]] \
  || fail "Deployment subscription or resource group does not match the allowlisted Redis resources for ${ENVIRONMENT}"

cache_id="${allowed_scope}/providers/Microsoft.Cache/Redis/${cache_name}"
endpoint_id="${allowed_scope}/providers/Microsoft.Network/privateEndpoints/${endpoint_name}"
az_args=(--subscription "${subscription_id}" --only-show-errors)

already_absent() {
  local error_codes='ResourceNotFound|ParentResourceNotFound|ResourceGroupNotFound'
  grep -Eq "^(Code: (${error_codes})$|ERROR: \((${error_codes})\)([[:space:]]|$))" <<<"$1"
}

read_resource() {
  local resource_id="$1" projection="$2" result
  if result="$(az resource show --ids "${resource_id}" "${az_args[@]}" --query "${projection}" -o json 2>&1)"; then
    [[ -n "${result}" ]] || return 1
    printf '%s\n' "${result}"
  elif ! already_absent "${result}"; then
    printf '%s\n' "${result}" >&2
    return 1
  fi
}

delete_resource() {
  local resource_id="$1" resource_json="$2" result
  if [[ -z "${resource_json}" ]]; then
    echo "Already absent: ${resource_id}"
  elif [[ "${DRY_RUN:-true}" != "false" ]]; then
    echo "Would delete ${resource_id}"
  elif result="$(az resource delete --ids "${resource_id}" "${az_args[@]}" -o none 2>&1)"; then
    echo "Deleted ${resource_id}"
  elif already_absent "${result}"; then
    echo "Already absent: ${resource_id}"
  else
    printf '%s\n' "${result}" >&2
    fail "Could not delete ${resource_id}"
  fi
}

# Check the bindings in both directions before any deletion. Either resource may
# already be absent after a previous run or a partial cleanup.
cache_json="$(read_resource "${cache_id}" '{id:id,endpoints:properties.privateEndpointConnections}')" \
  || fail "Could not read Azure Cache for Redis ${cache_name}"
endpoint_json="$(read_resource "${endpoint_id}" '{id:id,connections:properties.privateLinkServiceConnections,manualConnections:properties.manualPrivateLinkServiceConnections}')" \
  || fail "Could not read Redis private endpoint ${endpoint_name}"

if [[ -n "${cache_json}" ]]; then
  jq -e --arg cache "${cache_id}" --arg endpoint "${endpoint_id}" '
    (.id | ascii_downcase) == ($cache | ascii_downcase)
    and (.endpoints == null or (.endpoints | type) == "array")
    and all((.endpoints // [])[];
      (.properties.privateEndpoint.id | ascii_downcase) == ($endpoint | ascii_downcase)
    )
  ' <<<"${cache_json}" >/dev/null \
    || fail "Azure Cache for Redis ${cache_name} has unexpected private endpoint metadata"
fi

if [[ -n "${endpoint_json}" ]]; then
  jq -e --arg cache "${cache_id}" --arg endpoint "${endpoint_id}" '
    (.id | ascii_downcase) == ($endpoint | ascii_downcase)
    and (.connections == null or (.connections | type) == "array")
    and (.manualConnections == null or (.manualConnections | type) == "array")
    and (((.connections // []) + (.manualConnections // [])) |
      length == 1 and
      (.[0].properties.privateLinkServiceId | ascii_downcase) == ($cache | ascii_downcase)
    )
  ' <<<"${endpoint_json}" >/dev/null \
    || fail "Redis private endpoint ${endpoint_name} does not exclusively target ${cache_name}"
fi

delete_resource "${endpoint_id}" "${endpoint_json}"
delete_resource "${cache_id}" "${cache_json}"
