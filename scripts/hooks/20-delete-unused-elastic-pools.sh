#!/usr/bin/env bash
# IMTA-21420: Retire the empty SQL elastic pools removed from 40-infra.
set -euo pipefail

fail() {
  echo "##vso[task.logissue type=error]$*"
  echo "ERROR: $*" >&2
  exit 1
}

# Each environment may delete only the listed resource ID.
case "${ENVIRONMENT:-}" in
  dev) exit 0 ;;
  tst)
    pool_id='/subscriptions/0022ef8e-d44e-49c5-8cfd-5e8e9c6e913e/resourceGroups/TSTIMPINFRG1401/providers/Microsoft.Sql/servers/TSTIMPDBSSQ1401/elasticPools/TSTIMPDBSEP1401'
    ;;
  pre)
    pool_id='/subscriptions/3978eb4f-add1-415d-839b-db398e65a7d9/resourceGroups/PREIMPINFRG1401/providers/Microsoft.Sql/servers/PREIMPDBSSQ1401/elasticPools/PREIMPDBSEP1401'
    ;;
  prd)
    pool_id='/subscriptions/5f38dc6f-69b9-4d1b-9000-7e0b8277e515/resourceGroups/PRDIMPINFRG1401/providers/Microsoft.Sql/servers/PRDIMPDBSSQ1401/elasticPools/PRDIMPDBSEP1401'
    ;;
  *) fail "Expected ENVIRONMENT to be dev, tst, pre or prd" ;;
esac

subscription_id="$(tr '[:upper:]' '[:lower:]' <<<"${SUBSCRIPTION_ID:-}")"
resource_group="$(tr '[:lower:]' '[:upper:]' <<<"${RESOURCE_GROUP_NAME:-}")"
[[ "${pool_id}" == "/subscriptions/${subscription_id}/resourceGroups/${resource_group}/"* ]] \
  || fail "Deployment subscription or resource group does not match the allowlisted pool for ${ENVIRONMENT}"
pool="${pool_id##*/}"
pool_args=(--ids "${pool_id}" --only-show-errors)

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
