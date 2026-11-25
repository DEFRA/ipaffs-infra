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
  local environment="$1" group="$2" dry_run="$3" lookup="${4:-}"
  : > "${AZ_CALLS}"
  ENVIRONMENT="${environment}" RESOURCE_GROUP_NAME="${group}" SUBSCRIPTION_ID=sub-id \
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

touch "${POOL_PRESENT}"
[[ "$(run_hook dev "" false)" == "" && ! -s "${AZ_CALLS}" ]]
expect_failure "Expected resource group" tst PREIMPINFRG1401 false
[[ ! -s "${AZ_CALLS}" ]]

[[ "$(run_hook tst tstimpinfrg1401 "")" == "Would delete empty SQL elastic pool TSTIMPDBSEP1401" ]]
grep -qxF 'sql elastic-pool list-dbs --subscription sub-id --resource-group TSTIMPINFRG1401 --server TSTIMPDBSSQ1401 --name TSTIMPDBSEP1401 --only-show-errors --query length(@) -o tsv' "${AZ_CALLS}"
[[ "$(wc -l < "${AZ_CALLS}")" -eq 1 && -f "${POOL_PRESENT}" ]]

expect_failure "still contains 2 database(s)" prd PRDIMPINFRG1401 false occupied
[[ "$(wc -l < "${AZ_CALLS}")" -eq 1 ]]
expect_failure "Could not check databases" prd PRDIMPINFRG1401 false forbidden
[[ "$(wc -l < "${AZ_CALLS}")" -eq 1 ]]
expect_failure "Invalid database count" prd PRDIMPINFRG1401 false invalid
[[ "$(wc -l < "${AZ_CALLS}")" -eq 1 ]]
expect_failure "Could not delete" prd PRDIMPINFRG1401 false delete-failed
[[ -f "${POOL_PRESENT}" ]]

[[ "$(run_hook pre PREIMPINFRG1401 false)" == "Deleted empty SQL elastic pool PREIMPDBSEP1401" ]]
grep -qxF 'sql elastic-pool delete --subscription sub-id --resource-group PREIMPINFRG1401 --server PREIMPDBSSQ1401 --name PREIMPDBSEP1401 --only-show-errors -o none' "${AZ_CALLS}"
[[ "$(wc -l < "${AZ_CALLS}")" -eq 2 && ! -f "${POOL_PRESENT}" ]]
[[ "$(run_hook pre PREIMPINFRG1401 false)" == "SQL elastic pool PREIMPDBSEP1401 is already absent" ]]
[[ "$(wc -l < "${AZ_CALLS}")" -eq 1 ]]
[[ "$(run_hook prd PRDIMPINFRG1401 false missing-group)" == "SQL elastic pool PRDIMPDBSEP1401 is already absent" ]]
[[ "$(wc -l < "${AZ_CALLS}")" -eq 1 ]]

echo "All unused SQL elastic pool hook checks passed"
