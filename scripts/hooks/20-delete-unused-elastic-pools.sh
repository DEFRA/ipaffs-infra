#!/usr/bin/env bash
# IMTA-21420: Retire the empty SQL elastic pools removed from 40-infra.
set -euo pipefail

fail() {
  echo "##vso[task.logissue type=error]$*"
  echo "ERROR: $*" >&2
  exit 1
}

case "${ENVIRONMENT:-}" in
  dev) exit 0 ;;
  tst|pre|prd) ;;
  *) fail "Expected ENVIRONMENT to be dev, tst, pre or prd" ;;
esac

[[ -n "${SUBSCRIPTION_ID:-}" ]] || fail "SUBSCRIPTION_ID is not set"
prefix="$(tr '[:lower:]' '[:upper:]' <<<"${ENVIRONMENT}")IMP"
resource_group="$(tr '[:lower:]' '[:upper:]' <<<"${RESOURCE_GROUP_NAME:-}")"
[[ "${resource_group}" == "${prefix}INFRG1401" ]] \
  || fail "Expected resource group ${prefix}INFRG1401 for ${ENVIRONMENT}"
server="${prefix}DBSSQ1401"
pool="${prefix}DBSEP1401"
pool_args=(
  --subscription "${SUBSCRIPTION_ID}"
  --resource-group "${resource_group}"
  --server "${server}"
  --name "${pool}"
  --only-show-errors
)

# This lookup reports both whether the pool exists and whether deletion is safe.
if ! database_count="$(az sql elastic-pool list-dbs "${pool_args[@]}" --query 'length(@)' -o tsv 2>&1)"; then
  if grep -Eq '^Code: (ResourceNotFound|ParentResourceNotFound|ResourceGroupNotFound)$' <<<"${database_count}"; then
    echo "SQL elastic pool ${pool} is already absent"
    exit 0
  fi
  printf '%s\n' "${database_count}" >&2
  fail "Could not check databases in SQL elastic pool ${pool}"
fi

[[ "${database_count}" =~ ^[0-9]+$ ]] || fail "Invalid database count for SQL elastic pool ${pool}"
[[ "${database_count}" == "0" ]] || fail "SQL elastic pool ${pool} still contains ${database_count} database(s)"

if [[ "${DRY_RUN:-true}" != "false" ]]; then
  echo "Would delete empty SQL elastic pool ${pool}"
  exit 0
fi

az sql elastic-pool delete "${pool_args[@]}" -o none \
  || fail "Could not delete SQL elastic pool ${pool}"
echo "Deleted empty SQL elastic pool ${pool}"
