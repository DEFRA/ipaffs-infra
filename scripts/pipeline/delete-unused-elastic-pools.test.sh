#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="${script_dir}/../hooks/20-delete-unused-elastic-pools.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT
export PATH="${test_dir}:${PATH}"
export AZ_CALLS="${test_dir}/az-calls"
export POOL_PRESENT="${test_dir}/pool-present"

cat > "${test_dir}/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "${AZ_CALLS}"
case "$1 $2 $3" in
  "sql elastic-pool list-dbs")
    case "${LOOKUP:-}" in
      missing-group) echo "Code: ResourceGroupNotFound" >&2; exit 3 ;;
      forbidden) echo "Code: AuthorizationFailed" >&2; exit 1 ;;
      occupied) echo 2; exit 0 ;;
      invalid) exit 0 ;;
    esac
    if [[ ! -f "${POOL_PRESENT}" ]]; then
      echo "Code: ResourceNotFound" >&2
      exit 3
    fi
    echo 0
    ;;
  "sql elastic-pool delete")
    [[ "${LOOKUP:-}" != "delete-failed" ]] || exit 1
    rm -f "${POOL_PRESENT}"
    ;;
  *) exit 99 ;;
esac
EOF
chmod +x "${test_dir}/az"

run_hook() {
  local environment="$1" subscription="$2" group="$3" dry_run="$4" lookup="${5:-}"
  : > "${AZ_CALLS}"
  ENVIRONMENT="${environment}" RESOURCE_GROUP_NAME="${group}" SUBSCRIPTION_ID="${subscription}" \
    DRY_RUN="${dry_run}" LOOKUP="${lookup}" bash "${hook}"
}

expect_failure() {
  local diagnostic="$1"
  shift
  local output
  if output="$(run_hook "$@" 2>&1)" || [[ "${output}" != *"${diagnostic}"* ]]; then
    printf 'Expected failure containing %s\n%s\n' "${diagnostic}" "${output}" >&2
    exit 1
  fi
}

tst_subscription='0022ef8e-d44e-49c5-8cfd-5e8e9c6e913e'
pre_subscription='3978eb4f-add1-415d-839b-db398e65a7d9'
prd_subscription='5f38dc6f-69b9-4d1b-9000-7e0b8277e515'
tst_id="/subscriptions/${tst_subscription}/resourceGroups/TSTIMPINFRG1401/providers/Microsoft.Sql/servers/TSTIMPDBSSQ1401/elasticPools/TSTIMPDBSEP1401"
pre_id="/subscriptions/${pre_subscription}/resourceGroups/PREIMPINFRG1401/providers/Microsoft.Sql/servers/PREIMPDBSSQ1401/elasticPools/PREIMPDBSEP1401"
prd_id="/subscriptions/${prd_subscription}/resourceGroups/PRDIMPINFRG1401/providers/Microsoft.Sql/servers/PRDIMPDBSSQ1401/elasticPools/PRDIMPDBSEP1401"
wrong_scope="Deployment subscription or resource group does not match"

touch "${POOL_PRESENT}"
[[ "$(run_hook dev "" "" false)" == "" && ! -s "${AZ_CALLS}" ]]
expect_failure "${wrong_scope}" tst "${tst_subscription}" PREIMPINFRG1401 false
[[ ! -s "${AZ_CALLS}" ]]
expect_failure "${wrong_scope}" tst "${pre_subscription}" TSTIMPINFRG1401 false
[[ ! -s "${AZ_CALLS}" ]]

[[ "$(run_hook tst "${tst_subscription}" tstimpinfrg1401 "")" == "Would delete empty SQL elastic pool TSTIMPDBSEP1401" ]]
grep -qxF "sql elastic-pool list-dbs --ids ${tst_id} --only-show-errors --query length(@) -o tsv" "${AZ_CALLS}"
[[ "$(wc -l < "${AZ_CALLS}")" -eq 1 && -f "${POOL_PRESENT}" ]]

expect_failure "still contains 2 database(s)" prd "${prd_subscription}" PRDIMPINFRG1401 false occupied
grep -qxF "sql elastic-pool list-dbs --ids ${prd_id} --only-show-errors --query length(@) -o tsv" "${AZ_CALLS}"
[[ "$(wc -l < "${AZ_CALLS}")" -eq 1 ]]
expect_failure "Could not check databases" prd "${prd_subscription}" PRDIMPINFRG1401 false forbidden
[[ "$(wc -l < "${AZ_CALLS}")" -eq 1 ]]
expect_failure "Invalid database count" prd "${prd_subscription}" PRDIMPINFRG1401 false invalid
[[ "$(wc -l < "${AZ_CALLS}")" -eq 1 ]]
expect_failure "Could not delete" prd "${prd_subscription}" PRDIMPINFRG1401 false delete-failed
[[ -f "${POOL_PRESENT}" ]]

[[ "$(run_hook pre "${pre_subscription}" PREIMPINFRG1401 false)" == "Deleted empty SQL elastic pool PREIMPDBSEP1401" ]]
grep -qxF "sql elastic-pool delete --ids ${pre_id} --only-show-errors -o none" "${AZ_CALLS}"
[[ "$(wc -l < "${AZ_CALLS}")" -eq 2 && ! -f "${POOL_PRESENT}" ]]
[[ "$(run_hook pre "${pre_subscription}" PREIMPINFRG1401 false)" == "SQL elastic pool PREIMPDBSEP1401 is already absent" ]]
[[ "$(wc -l < "${AZ_CALLS}")" -eq 1 ]]
[[ "$(run_hook prd "${prd_subscription}" PRDIMPINFRG1401 false missing-group)" == "SQL elastic pool PRDIMPDBSEP1401 is already absent" ]]
[[ "$(wc -l < "${AZ_CALLS}")" -eq 1 ]]

echo "All unused SQL elastic pool hook checks passed"
