#!/usr/bin/env bash

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/snd-app-services.sh"
work_dir="$(mktemp -d)"

cleanup_test_files() {
  if [[ "${KEEP_TEST_WORK_DIR:-false}" == "true" ]]; then
    echo "Test files retained at ${work_dir}"
  else
    rm -rf "${work_dir}"
  fi
}

trap cleanup_test_files EXIT

failures=0

check() {
  local name="$1"
  local expected="$2"
  local actual="$3"

  if [[ "${actual}" == "${expected}" ]]; then
    echo "ok   - ${name}"
  else
    echo "FAIL - ${name}: expected '${expected}' but got '${actual}'"
    failures=$((failures + 1))
  fi
}

check_output_contains() {
  local name="$1"
  local expected="$2"

  check "${name}" "true" "$(grep -qF -- "${expected}" "${case_output}" && printf true || printf false)"
}

count_calls() {
  local pattern="$1"

  grep -cF -- "${pattern}" "${case_az_log}" 2>/dev/null || true
}

count_resource_deletes() {
  grep -v '^lock ' "${case_az_log}" 2>/dev/null | grep -cF -- " delete" || true
}

# Line number of the first az call containing a pattern
first_line() {
  grep -nF -- "$1" "${case_az_log}" | head -1 | cut -d: -f1
}

# Line number of the last az call containing a pattern
last_line() {
  grep -nF -- "$1" "${case_az_log}" | tail -1 | cut -d: -f1
}

before() {
  [[ -n "$1" && -n "$2" && "$1" -lt "$2" ]] && printf true || printf false
}

count_exact_calls() {
  local line="$1"

  grep -cxF -- "${line}" "${case_az_log}" 2>/dev/null || true
}

fake_bin="${work_dir}/bin"
mkdir -p "${fake_bin}"

# Fake az serving one resource group with two plans
cat > "${fake_bin}/az" <<'EOF'
#!/usr/bin/env bash

printf '%s\n' "$*" >> "${FAKE_AZ_LOG}"

rg_id="/subscriptions/sub/resourceGroups/SNDIMPTEST-RG"
plan_a="${rg_id}/providers/Microsoft.Web/serverfarms/plan-a"
plan_b="${rg_id}/providers/Microsoft.Web/serverfarms/plan-b"
site_a="${rg_id}/providers/Microsoft.Web/sites/site-a"
plan_a_upper="$(tr '[:lower:]' '[:upper:]' <<<"${plan_a}")"

case "$*" in
  "group show"*)
    [[ "$*" == *"--name SNDIMPMISSING-RG"* ]] && exit 3
    exit 0
    ;;
  "lock list"*)
    case "${FAKE_AZ_SCENARIO}" in
      other-lock) echo '[{"name":"team-no-delete","level":"CanNotDelete"}]' ;;
      orphaned-lock) echo '[{"name":"ipaffs-pipeline-run","level":"CanNotDelete"}]' ;;
      read-only) echo '[{"name":"freeze","level":"ReadOnly"}]' ;;
      *) echo '[]' ;;
    esac
    ;;
  "appservice plan update"*)
    [[ "${FAKE_AZ_SCENARIO}" == "fail-scale" ]] && exit 1
    exit 0
    ;;
  "lock delete"*)
    [[ "${FAKE_AZ_SCENARIO}" == "fail-unlock" ]] && exit 1
    exit 0
    ;;
  "resource list"*"Microsoft.Insights/autoscalesettings"*)
    echo "SNDIMPTEST-RG"
    ;;
  "resource list"*"Microsoft.Web/sites/slots"*)
    echo "${site_a}/slots/staging"
    ;;
  "monitor autoscale list"*)
    printf '[{"name":"plan-a-autoscale","resourceGroup":"SNDIMPTEST-RG","enabled":true,"target":"%s"}]\n' "${plan_a_upper}"
    ;;
  "appservice plan list"*)
    if [[ "${FAKE_AZ_SCENARIO}" == "tagged" ]]; then
      tags_a='{"ipaffs-disabled":"2026-10-01","ipaffs-original-sku":"P2v3"}'
    else
      tags_a='null'
    fi
    printf '[{"id":"%s","name":"plan-a","resourceGroup":"SNDIMPTEST-RG","sku":"P2v3","capacity":3,"tags":%s},' "${plan_a}" "${tags_a}"
    printf '{"id":"%s","name":"plan-b","resourceGroup":"SNDIMPTEST-RG","sku":"P1v3","capacity":1,"tags":null}]\n' "${plan_b}"
    ;;
  "webapp list"*)
    printf '[{"id":"%s","name":"site-a","kind":"app,linux,container","state":"Running","plan":"%s"},' "${site_a}" "${plan_a_upper}"
    printf '{"id":"%s/providers/Microsoft.Web/sites/site-b","name":"site-b","kind":"app,linux","state":"Stopped","plan":"%s"}]\n' "${rg_id}" "${plan_b}"
    ;;
  "functionapp list"*)
    printf '[{"id":"%s/providers/Microsoft.Web/sites/func-b","name":"func-b","kind":"functionapp,linux","state":"Running","plan":"%s"}]\n' "${rg_id}" "${plan_b}"
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "${fake_bin}/az"

targets_file="${work_dir}/targets.txt"
printf '# test targets\n\nSNDIMPTEST-RG  # trailing comment\n' > "${targets_file}"

run_case() {
  local name="$1"
  local action="$2"
  shift 2

  case_az_log="${work_dir}/${name}.az.log"
  case_output="${work_dir}/${name}.out"
  : > "${case_az_log}"

  env PATH="${fake_bin}:${PATH}" \
    FAKE_AZ_LOG="${case_az_log}" \
    FAKE_AZ_SCENARIO="${FAKE_AZ_SCENARIO:-default}" \
    SUBSCRIPTION_NAME="${SUBSCRIPTION_NAME:-AZR-SND}" \
    TARGETS_FILE="${TARGETS_FILE:-${targets_file}}" \
    "$@" \
    bash "${script_path}" "${action}" > "${case_output}" 2>&1
  case_status=$?
}

echo "disable"
run_case disable disable DRY_RUN=false
check "disable succeeds" "0" "${case_status}"
check "tags plan a once" "1" "$(count_calls "tag update --resource-id /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/serverfarms/plan-a")"
check "records original sku" "1" "$(count_calls "ipaffs-original-sku=P2v3 ipaffs-original-capacity=3 ipaffs-autoscale-enabled=true")"
check "records plan b without autoscale" "1" "$(count_calls "ipaffs-original-sku=P1v3 ipaffs-original-capacity=1 ipaffs-autoscale-enabled=false")"
check "turns off autoscale" "1" "$(count_calls "monitor autoscale update --subscription AZR-SND --resource-group SNDIMPTEST-RG --name plan-a-autoscale --enabled false")"
check "stops running web app" "1" "$(count_exact_calls "webapp stop --ids /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/sites/site-a")"
check "stops slot" "1" "$(count_calls "webapp stop --ids /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/sites/site-a/slots/staging")"
check "stops running function app" "1" "$(count_calls "functionapp stop --ids /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/sites/func-b")"
check "skips stopped app" "0" "$(count_calls "sites/site-b")"
check "scales slot plan to S1" "1" "$(count_calls "serverfarms/plan-a --sku S1 --number-of-workers 1")"
check "scales plain plan to B1" "1" "$(count_calls "serverfarms/plan-b --sku B1 --number-of-workers 1")"
check "never deletes" "0" "$(count_resource_deletes)"
check "locks resource group once" "1" "$(count_calls "lock create --subscription AZR-SND --resource-group SNDIMPTEST-RG --name ipaffs-pipeline-run --lock-type CanNotDelete")"
check "locks before first stop" "true" "$(before "$(first_line "lock create")" "$(first_line " stop ")")"
check "unlocks resource group once" "1" "$(count_calls "lock delete --subscription AZR-SND --resource-group SNDIMPTEST-RG --name ipaffs-pipeline-run")"
check "unlocks after last scale" "true" "$(before "$(last_line "plan update")" "$(last_line "lock delete")")"

echo "disable dry run"
run_case disable-dry-run disable DRY_RUN=true
check "dry run succeeds" "0" "${case_status}"
check "dry run makes no tag change" "0" "$(count_calls "tag update")"
check "dry run makes no stop" "0" "$(count_calls " stop ")"
check "dry run makes no scale" "0" "$(count_calls "plan update")"
check "dry run makes no autoscale change" "0" "$(count_calls "autoscale update")"
check "dry run makes no lock call" "0" "$(( $(count_calls "lock create") + $(count_calls "lock delete") ))"
check_output_contains "dry run prints lock" "DRY RUN: az lock create"
check_output_contains "dry run prints scale" "DRY RUN: az appservice plan update"

echo "disable rerun"
FAKE_AZ_SCENARIO=tagged run_case disable-tagged disable DRY_RUN=false
check "rerun succeeds" "0" "${case_status}"
check "rerun keeps original tags" "0" "$(count_calls "serverfarms/plan-a --operation Merge")"
check "rerun tags untagged plan" "1" "$(count_calls "serverfarms/plan-b --operation Merge")"

echo "delete is always a dry run"
run_case delete delete DRY_RUN=false
check "delete succeeds" "0" "${case_status}"
check "delete runs no az delete" "0" "$(count_resource_deletes)"
check "delete locks resource group" "1" "$(count_calls "lock create")"
check "delete locks before listing" "true" "$(before "$(first_line "lock create")" "$(first_line "appservice plan list")")"
check "delete unlocks resource group" "1" "$(count_calls "lock delete")"
check_output_contains "delete reports lock" "is locked for this run, delete commands are printed only"
check "delete makes no change" "0" "$(count_calls " stop ")"
check_output_contains "delete prints slot" "DRY RUN: az webapp deployment slot delete"
check_output_contains "delete prints web app" "DRY RUN: az webapp delete --ids /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/sites/site-a --keep-empty-plan"
check_output_contains "delete prints function app" "DRY RUN: az functionapp delete --ids"
check_output_contains "delete prints plan" "DRY RUN: az appservice plan delete --ids /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/serverfarms/plan-b --yes"
check_output_contains "delete warns about plan not disabled" "has not been disabled yet"

echo "guards"
SUBSCRIPTION_NAME=AZR-TST run_case wrong-subscription disable DRY_RUN=false
check "rejects other subscription" "1" "${case_status}"
check "wrong subscription makes no az call" "0" "$(grep -c . "${case_az_log}")"

printf 'OTHER-RG\n' > "${work_dir}/other-targets.txt"
TARGETS_FILE="${work_dir}/other-targets.txt" run_case wrong-prefix disable DRY_RUN=false
check "rejects resource group outside prefix" "1" "${case_status}"

printf 'SNDIMPTEST-RG\nSNDIMPMISSING-RG\n' > "${work_dir}/missing-targets.txt"
TARGETS_FILE="${work_dir}/missing-targets.txt" run_case missing-rg disable DRY_RUN=false
check "rejects missing resource group" "1" "${case_status}"
check "missing resource group makes no change" "0" "$(count_calls " stop ")"
check "missing resource group adds no lock" "0" "$(count_calls "lock create")"

echo "locks"
FAKE_AZ_SCENARIO=read-only run_case read-only disable DRY_RUN=false
check "rejects ReadOnly lock" "1" "${case_status}"
check "ReadOnly lock adds no lock" "0" "$(count_calls "lock create")"
check "ReadOnly lock makes no change" "0" "$(count_calls " stop ")"

FAKE_AZ_SCENARIO=other-lock run_case other-lock disable DRY_RUN=false
check "works alongside another lock" "0" "${case_status}"
check "still stops apps with another lock" "1" "$(count_calls "functionapp stop")"
check "never removes another lock" "0" "$(count_calls "team-no-delete")"

FAKE_AZ_SCENARIO=orphaned-lock run_case orphaned-lock disable DRY_RUN=false
check "adopts orphaned run lock" "0" "${case_status}"
check "adopted lock is not created again" "0" "$(count_calls "lock create")"
check "adopted lock is removed" "1" "$(count_calls "lock delete")"

FAKE_AZ_SCENARIO=fail-scale run_case fail-scale disable DRY_RUN=false
check "failed run exits non zero" "1" "$(( case_status != 0 ))"
check "failed run still unlocks" "1" "$(count_calls "lock delete")"

FAKE_AZ_SCENARIO=fail-unlock run_case fail-unlock disable DRY_RUN=false
check "failed unlock fails the run" "1" "${case_status}"
check_output_contains "failed unlock is reported" "Could not remove lock 'ipaffs-pipeline-run'"

never_unlocks_other=0
for log_file in "${work_dir}"/*.az.log; do
  if grep -q "^lock delete" "${log_file}" && grep "^lock delete" "${log_file}" | grep -qv -- "--name ipaffs-pipeline-run"; then
    never_unlocks_other=$((never_unlocks_other + 1))
  fi
done
check "only the run lock is ever removed" "0" "${never_unlocks_other}"

run_case bad-action stop DRY_RUN=false
check "rejects unknown action" "1" "${case_status}"

if [[ "${failures}" -gt 0 ]]; then
  echo "${failures} check(s) failed"
  exit 1
fi

echo "All checks passed"
