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
  "webapp stop --ids ${site_a}")
    [[ "${FAKE_AZ_SCENARIO}" == "fail-stop" ]] && exit 1
    if [[ "${FAKE_AZ_SCENARIO}" == throttle* ]]; then
      throttle_file="${FAKE_AZ_LOG}.throttled"
      if [[ "${FAKE_AZ_SCENARIO}" == "throttle-always" || ! -f "${throttle_file}" ]]; then
        touch "${throttle_file}"
        echo 'ERROR: (ProviderError) {"Code":"429","Message":"PATCH Operation is currently throttled"}' >&2
        exit 1
      fi
    fi
    exit 0
    ;;
  "webapp start --ids ${site_a}")
    [[ "${FAKE_AZ_SCENARIO}" == *fail-start ]] && exit 1
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
    [[ "${FAKE_AZ_SCENARIO}" == "fail-list" ]] && exit 1
    sku_a="P2v3"
    capacity_a=3
    zone_a=false
    [[ "${FAKE_AZ_SCENARIO}" == "zone-redundant" ]] && zone_a=true
    case "${FAKE_AZ_SCENARIO}" in
      tagged)
        tags_a='{"ipaffs-disabled":"2026-10-01","ipaffs-original-sku":"P2v3"}'
        ;;
      disabled*)
        tags_a='{"ipaffs-disabled":"2026-10-01","ipaffs-original-sku":"P2v3","ipaffs-original-capacity":"3","ipaffs-autoscale-off":"SNDIMPTEST-RG/plan-a-autoscale","ipaffs-stopped-1":"site-a,site-a/slots/staging"}'
        sku_a="S1"
        capacity_a=1
        ;;
      *)
        tags_a='null'
        ;;
    esac
    printf '[{"id":"%s","name":"plan-a","resourceGroup":"SNDIMPTEST-RG","sku":"%s","capacity":%s,"zoneRedundant":%s,"tags":%s},' "${plan_a}" "${sku_a}" "${capacity_a}" "${zone_a}" "${tags_a}"
    printf '{"id":"%s","name":"plan-b","resourceGroup":"SNDIMPTEST-RG","sku":"P1v3","capacity":1,"tags":null}]\n' "${plan_b}"
    ;;
  "monitor diagnostic-settings list --resource ${site_a} "*)
    echo '[{"name":"send-all","logs":[{"category":"AppServiceHTTPLogs","enabled":true},{"category":"AppServiceFileAuditLogs","enabled":true},{"category":"AppServiceAntivirusScanAuditLogs","enabled":true}]}]'
    ;;
  "monitor diagnostic-settings list"*"sites/func-b "*)
    echo '[{"name":"send-all","logs":[{"category":"AppServiceFileAuditLogs","enabled":false}]}]'
    ;;
  "monitor diagnostic-settings list"*)
    echo '[]'
    ;;
  "monitor diagnostic-settings show"*)
    # Azure hides Premium only categories while the plan is small
    if [[ "${FAKE_AZ_SCENARIO}" == *hidden-logs ]]; then
      echo '{"name":"send-all","logs":[{"category":"AppServiceHTTPLogs","enabled":true}]}'
    else
      echo '{"name":"send-all","logs":[{"category":"AppServiceHTTPLogs","enabled":true},{"category":"AppServiceFileAuditLogs","enabled":false},{"category":"AppServiceAntivirusScanAuditLogs","enabled":false}]}'
    fi
    ;;
  "webapp list"*)
    case "${FAKE_AZ_SCENARIO}" in
      audit-tagged) tags_site_a='{"ipaffs-file-audit-off":"older-setting:AppServiceFileAuditLogs"}' ;;
      disabled*) tags_site_a='{"ipaffs-file-audit-off":"send-all:AppServiceAntivirusScanAuditLogs,send-all:AppServiceFileAuditLogs"}' ;;
      *) tags_site_a='null' ;;
    esac
    printf '[{"id":"%s","name":"site-a","kind":"app,linux,container","state":"Running","plan":"%s","tags":%s},' "${site_a}" "${plan_a_upper}" "${tags_site_a}"
    printf '{"id":"%s/providers/Microsoft.Web/sites/site-b","name":"site-b","kind":"app,linux","state":"Stopped","plan":"%s"}]\n' "${rg_id}" "${plan_b}"
    ;;
  "functionapp list"*)
    if [[ "${FAKE_AZ_SCENARIO}" == "many-apps" ]]; then
      printf '['
      for n in 01 02 03 04 05 06 07 08 09 10 11 12; do
        printf '{"id":"%s/providers/Microsoft.Web/sites/very-long-application-name-for-chunking-%s","name":"very-long-application-name-for-chunking-%s","kind":"functionapp","state":"Running","plan":"%s"},' "${rg_id}" "${n}" "${n}" "${plan_b}"
      done
      printf '{"id":"%s/providers/Microsoft.Web/sites/func-b","name":"func-b","kind":"functionapp,linux","state":"Running","plan":"%s"}]\n' "${rg_id}" "${plan_b}"
      exit 0
    fi
    printf '[{"id":"%s/providers/Microsoft.Web/sites/func-b","name":"func-b","kind":"functionapp,linux","state":"Running","plan":"%s"}]\n' "${rg_id}" "${plan_b}"
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "${fake_bin}/az"

# Fake curl serving the Azure DevOps OIDC token endpoint
cat > "${fake_bin}/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "${FAKE_AZ_LOG}"
echo '{"oidcToken":"fake-oidc-token"}'
EOF
chmod +x "${fake_bin}/curl"

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
check "records original sku" "1" "$(count_calls "ipaffs-original-sku=P2v3 ipaffs-original-capacity=3 ipaffs-autoscale-off=SNDIMPTEST-RG/plan-a-autoscale")"
check "records plan b without autoscale" "1" "$(count_calls "ipaffs-original-sku=P1v3 ipaffs-original-capacity=1 ipaffs-autoscale-off=none")"
check "turns off autoscale" "1" "$(count_calls "monitor autoscale update --subscription AZR-SND --resource-group SNDIMPTEST-RG --name plan-a-autoscale --enabled false")"
check "stops running web app" "1" "$(count_exact_calls "webapp stop --ids /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/sites/site-a")"
check "stops slot" "1" "$(count_calls "webapp stop --ids /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/sites/site-a/slots/staging")"
check "stops running function app" "1" "$(count_calls "functionapp stop --ids /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/sites/func-b")"
check "skips stopped app" "0" "$(count_calls "stop --ids /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/sites/site-b")"
check "scales slot plan to S1" "1" "$(count_calls "serverfarms/plan-a --sku S1 --number-of-workers 1")"
check "scales plain plan to B1" "1" "$(count_calls "serverfarms/plan-b --sku B1 --number-of-workers 1")"
check "never deletes" "0" "$(count_resource_deletes)"
check "disable adds no lock" "0" "$(count_calls "lock create")"
check "disable removes no lock" "0" "$(count_calls "lock delete")"
check "tags app before turning off audit logs" "1" "$(count_exact_calls "tag update --resource-id /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/sites/site-a --operation Merge --tags ipaffs-file-audit-off=send-all:AppServiceAntivirusScanAuditLogs,send-all:AppServiceFileAuditLogs --output none")"
check "turns off audit logs" "1" "$(count_exact_calls "monitor diagnostic-settings update --resource /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/sites/site-a --name send-all --set logs[1].enabled=false --output none")"
check "turns off antivirus logs" "1" "$(count_exact_calls "monitor diagnostic-settings update --resource /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/sites/site-a --name send-all --set logs[2].enabled=false --output none")"
check "audit logs off before scaling" "true" "$(before "$(first_line "diagnostic-settings update")" "$(first_line "serverfarms/plan-a --sku")")"
check "tag before audit logs off" "true" "$(before "$(first_line "ipaffs-file-audit-off")" "$(first_line "diagnostic-settings update")")"
check "leaves audit logs already off" "0" "$(count_calls "sites/func-b --name")"
check "checks slot audit logs" "1" "$(count_calls "diagnostic-settings list --resource /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/sites/site-a/slots/staging")"
check "changes only premium logs" "2" "$(count_calls "diagnostic-settings update")"
check "lists stopped app and slot on the plan" "1" "$(count_calls "serverfarms/plan-a --operation Merge --tags ipaffs-original-sku=P2v3 ipaffs-original-capacity=3 ipaffs-autoscale-off=SNDIMPTEST-RG/plan-a-autoscale ipaffs-disabled=")"
check "plan a stop list" "1" "$(count_calls "ipaffs-stopped-1=site-a,site-a/slots/staging --output none")"
check "plan b stop list leaves out app already stopped" "1" "$(count_calls "ipaffs-stopped-1=func-b --output none")"
check "tags no app for stopping" "0" "$(grep -F "tag update" "${case_az_log}" | grep -F "/sites/" | grep -cF "ipaffs-stopped" || true)"
check "records stops before stopping" "true" "$(before "$(first_line "ipaffs-stopped-1=func-b")" "$(first_line "functionapp stop")")"

echo "disable dry run"
run_case disable-dry-run disable DRY_RUN=true
check "dry run succeeds" "0" "${case_status}"
check "dry run makes no tag change" "0" "$(count_calls "tag update")"
check "dry run makes no stop" "0" "$(count_calls " stop ")"
check "dry run makes no scale" "0" "$(count_calls "plan update")"
check "dry run makes no autoscale change" "0" "$(count_calls "autoscale update")"
check "dry run makes no lock call" "0" "$(( $(count_calls "lock create") + $(count_calls "lock delete") ))"
check "dry run makes no diagnostic change" "0" "$(count_calls "diagnostic-settings update")"
check_output_contains "dry run prints scale" "DRY RUN: az appservice plan update"
check_output_contains "dry run prints audit logs off" "DRY RUN: az monitor diagnostic-settings update"

echo "disable rerun"
FAKE_AZ_SCENARIO=zone-redundant run_case zone-redundant disable DRY_RUN=false
check "scales zone redundant plan to smallest Premium" "1" "$(count_calls "serverfarms/plan-a --sku P0v3 --number-of-workers 3")"
check "zone redundant plan never goes below Premium" "0" "$(count_calls "serverfarms/plan-a --sku S1")"
check "zone redundant plan keeps Premium logs" "0" "$(count_calls "diagnostic-settings update")"
check "zone redundant plan still stops apps" "1" "$(count_exact_calls "webapp stop --ids /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/sites/site-a")"
check "other plan still scales to B1" "1" "$(count_calls "serverfarms/plan-b --sku B1 --number-of-workers 1")"

FAKE_AZ_SCENARIO=tagged run_case disable-tagged disable DRY_RUN=false
check "rerun succeeds" "0" "${case_status}"
check "rerun keeps original tags" "0" "$(count_calls "serverfarms/plan-a --operation Merge --tags ipaffs-original")"
check "rerun adds stop list to tagged plan" "1" "$(count_calls "serverfarms/plan-a --operation Merge --tags ipaffs-stopped-1=site-a,site-a/slots/staging")"

FAKE_AZ_SCENARIO=disabled run_case disable-recorded disable DRY_RUN=false
check "rerun with nothing new writes no plan tag" "0" "$(count_calls "serverfarms/plan-a --operation Merge")"

FAKE_AZ_SCENARIO=many-apps run_case many-apps disable DRY_RUN=false
check "long stop list is split" "true" "$(grep -qF "ipaffs-stopped-2=" "${case_az_log}" && printf true || printf false)"
check "every stop tag fits" "0" "$(grep -F "serverfarms/plan-b --operation Merge" "${case_az_log}" | tr ' ' '\n' | grep '^ipaffs-stopped-' | awk '{ sub(/^[^=]*=/, ""); if (length($0) > 256) n++ } END { print n + 0 }')"
check "split stop list keeps every app" "13" "$(grep -F "serverfarms/plan-b --operation Merge" "${case_az_log}" | tr ' ' '\n' | grep '^ipaffs-stopped-' | sed 's/^[^=]*=//' | tr ',' '\n' | grep -c .)"
check "rerun tags untagged plan" "1" "$(count_calls "serverfarms/plan-b --operation Merge")"

FAKE_AZ_SCENARIO=audit-tagged run_case disable-audit-tagged disable DRY_RUN=false
check "rerun keeps recorded audit settings" "1" "$(count_calls "ipaffs-file-audit-off=older-setting:AppServiceFileAuditLogs,send-all:AppServiceAntivirusScanAuditLogs,send-all:AppServiceFileAuditLogs")"

echo "restore"
FAKE_AZ_SCENARIO=disabled run_case restore restore DRY_RUN=false
check "restore succeeds" "0" "${case_status}"
check "restores plan size" "1" "$(count_exact_calls "appservice plan update --ids /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/serverfarms/plan-a --sku P2v3 --number-of-workers 3 --output none")"
check "leaves plan not disabled alone" "0" "$(count_calls "serverfarms/plan-b --")"
check "turns autoscale back on" "1" "$(count_exact_calls "monitor autoscale update --subscription AZR-SND --resource-group SNDIMPTEST-RG --name plan-a-autoscale --enabled true --output none")"
check "turns audit logs back on" "1" "$(count_exact_calls "monitor diagnostic-settings update --resource /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/sites/site-a --name send-all --set logs[1].enabled=true --output none")"
check "turns antivirus logs back on" "1" "$(count_exact_calls "monitor diagnostic-settings update --resource /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/sites/site-a --name send-all --set logs[2].enabled=true --output none")"
check "scales up before audit logs" "true" "$(before "$(first_line "plan update")" "$(first_line "diagnostic-settings update")")"
check "starts app disable stopped" "1" "$(count_exact_calls "webapp start --ids /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/sites/site-a")"
check "starts slot disable stopped" "1" "$(count_exact_calls "webapp start --ids /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/sites/site-a/slots/staging")"
check "starts nothing else" "2" "$(count_calls " start ")"
check "removes stop list with plan tags" "1" "$(count_calls "serverfarms/plan-a --operation Delete --tags ipaffs-original-sku ipaffs-original-capacity ipaffs-autoscale-off ipaffs-disabled ipaffs-stopped-1 --output none")"
check "removes audit tag" "1" "$(count_calls "sites/site-a --operation Delete --tags ipaffs-file-audit-off")"
check "removes plan tags last" "true" "$(before "$(last_line " start ")" "$(first_line "serverfarms/plan-a --operation Delete")")"
check "restore never deletes" "0" "$(grep -v -- '--operation Delete' "${case_az_log}" | grep -v '^lock ' | grep -cF " delete" || true)"
check "restore adds no lock" "0" "$(count_calls "lock create")"

FAKE_AZ_SCENARIO=disabled-hidden-logs run_case restore-hidden restore DRY_RUN=false RESTORE_LOG_ATTEMPTS=2 RESTORE_LOG_DELAY_SECONDS=0
check "hidden logs fail restore" "1" "${case_status}"
check_output_contains "hidden logs are reported" "did not come back in diagnostic setting 'send-all'"
check "hidden logs are retried" "true" "$( (( $(count_calls "diagnostic-settings show") >= 2 )) && printf true || printf false)"
check "hidden logs keep the audit tag" "0" "$(count_calls "sites/site-a --operation Delete --tags ipaffs-file-audit-off")"
check "hidden logs keep the plan tags" "0" "$(count_calls "serverfarms/plan-a --operation Delete")"

FAKE_AZ_SCENARIO=disabled-hidden-logs run_case restore-hidden-dry-run restore DRY_RUN=true RESTORE_LOG_ATTEMPTS=3 RESTORE_LOG_DELAY_SECONDS=5
check "hidden logs dry run succeeds" "0" "${case_status}"
check "hidden logs dry run does not wait" "2" "$(count_calls "diagnostic-settings show")"
check_output_contains "hidden logs dry run explains" "is hidden until the plan is scaled up"

FAKE_AZ_SCENARIO=disabled run_case restore-dry-run restore DRY_RUN=true
check "restore dry run succeeds" "0" "${case_status}"
check "restore dry run makes no change" "0" "$(( $(count_calls " start ") + $(count_calls "plan update") + $(count_calls "tag update") + $(count_calls "autoscale update") ))"
check_output_contains "restore dry run prints scale" "DRY RUN: az appservice plan update"

run_case restore-nothing restore DRY_RUN=false
check "restore with nothing disabled changes nothing" "0" "$(( $(count_calls " start ") + $(count_calls "plan update") + $(count_calls "tag update") ))"

echo "parallel"
FAKE_AZ_SCENARIO=fail-stop run_case fail-stop disable DRY_RUN=false
check "failed stop fails the run" "1" "${case_status}"
check_output_contains "failed stop is reported" "Could not disable every app on plan 'plan-a'"
check "failed stop leaves plan unscaled" "0" "$(count_calls "plan update")"
check "failed stop skips audit logs for that app" "0" "$(count_calls "diagnostic-settings list --resource /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/sites/site-a ")"

FAKE_AZ_SCENARIO=disabled-fail-start run_case fail-start restore DRY_RUN=false
check "failed start fails restore" "1" "${case_status}"
check "failed start keeps plan tags" "0" "$(count_calls "serverfarms/plan-a --operation Delete")"

run_case one-job disable DRY_RUN=false PARALLEL_JOBS=1
check "one job at a time works" "0" "${case_status}"
check "one job at a time stops the same apps" "3" "$(count_calls " stop --ids")"

run_case bad-jobs disable DRY_RUN=false PARALLEL_JOBS=0
check "rejects bad PARALLEL_JOBS" "1" "${case_status}"

FAKE_AZ_SCENARIO=throttle-once run_case throttle-once disable DRY_RUN=false THROTTLE_DELAY_SECONDS=0
check "throttled change is retried" "0" "${case_status}"
check "throttled stop runs twice" "2" "$(count_exact_calls "webapp stop --ids /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/sites/site-a")"
check_output_contains "throttling is reported" "Azure is throttling, retrying 'az webapp'"

FAKE_AZ_SCENARIO=throttle-always run_case throttle-always disable DRY_RUN=false THROTTLE_DELAY_SECONDS=0 THROTTLE_ATTEMPTS=3
check "endless throttling fails the run" "1" "${case_status}"
check "endless throttling gives up after the limit" "3" "$(count_exact_calls "webapp stop --ids /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/sites/site-a")"
check "endless throttling leaves plan unscaled" "0" "$(count_calls "serverfarms/plan-a --sku")"

check "other errors are not retried" "1" "$(grep -cxF "webapp stop --ids /subscriptions/sub/resourceGroups/SNDIMPTEST-RG/providers/Microsoft.Web/sites/site-a" "${work_dir}/fail-stop.az.log")"

echo "sign in refresh"
run_case no-refresh disable DRY_RUN=false
check "no sign in outside the pipeline" "0" "$(count_calls "login --service-principal")"

pipeline_env=(SYSTEM_OIDCREQUESTURI=https://dev.azure.com/org/project/_apis/distributedtask/hubs/build/plans/plan/jobs/job/oidctoken
  SYSTEM_ACCESSTOKEN=fake-access-token AZURESUBSCRIPTION_SERVICE_CONNECTION_ID=conn-id
  AZURESUBSCRIPTION_CLIENT_ID=client-id AZURESUBSCRIPTION_TENANT_ID=tenant-id)
run_case refresh disable DRY_RUN=false "${pipeline_env[@]}" LOGIN_REFRESH_SECONDS=0
check "refresh succeeds" "0" "${case_status}"
check "signs in again before each plan" "2" "$(count_calls "login --service-principal --username client-id --tenant tenant-id --federated-token fake-oidc-token")"
check "asks for token for the service connection" "2" "$(count_calls "oidctoken?api-version=7.1&serviceConnectionId=conn-id")"
check "selects the subscription after sign in" "2" "$(count_calls "account set --subscription AZR-SND")"
check_output_contains "never prints the token" "Signing in to Azure again"
check "token is not in the output" "false" "$(grep -qF fake-oidc-token "${case_output}" && printf true || printf false)"

run_case no-refresh-yet disable DRY_RUN=false "${pipeline_env[@]}"
check "no sign in before the interval" "0" "$(count_calls "login --service-principal")"

run_case refresh-missing disable DRY_RUN=false SYSTEM_OIDCREQUESTURI=https://example
check_output_contains "warns when refresh is not possible" "sign in cannot be refreshed"

echo "delete is always a dry run"
run_case delete delete DRY_RUN=false
check "delete succeeds" "0" "${case_status}"
check "delete runs no az delete" "0" "$(count_resource_deletes)"
check "delete locks resource group" "1" "$(count_calls "lock create --subscription AZR-SND --resource-group SNDIMPTEST-RG --name ipaffs-pipeline-run --lock-type CanNotDelete")"
check "delete locks before listing" "true" "$(before "$(first_line "lock create")" "$(first_line "appservice plan list")")"
check "delete unlocks resource group" "1" "$(count_calls "lock delete --subscription AZR-SND --resource-group SNDIMPTEST-RG --name ipaffs-pipeline-run")"
check "delete unlocks after listing" "true" "$(before "$(last_line "appservice plan list")" "$(last_line "lock delete")")"
check_output_contains "delete reports lock" "Locking resource group 'SNDIMPTEST-RG' with CanNotDelete lock"
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

FAKE_AZ_SCENARIO=other-lock run_case other-lock-disable disable DRY_RUN=false
check "disable works alongside another lock" "0" "${case_status}"
check "still stops apps with another lock" "1" "$(count_calls "functionapp stop")"

FAKE_AZ_SCENARIO=other-lock run_case other-lock delete
check "delete works alongside another lock" "0" "${case_status}"
check "never removes another lock" "0" "$(count_calls "team-no-delete")"

FAKE_AZ_SCENARIO=orphaned-lock run_case orphaned-lock delete
check "handles leftover run lock" "0" "${case_status}"
check "leftover lock is recreated" "1" "$(count_calls "lock create")"
check "leftover lock is removed" "1" "$(count_calls "lock delete")"

FAKE_AZ_SCENARIO=fail-list run_case fail-list delete
check "failed run exits non zero" "1" "$(( case_status != 0 ))"
check "failed run still unlocks" "1" "$(count_calls "lock delete")"

FAKE_AZ_SCENARIO=fail-unlock run_case fail-unlock delete
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
