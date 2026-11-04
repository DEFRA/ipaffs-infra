#!/usr/bin/env bash

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/disable.sh"
work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

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

# The fake az keeps site states in a TSV file and logs every stop or start.
# FAKE_AZ_SCENARIO adds throttling or apps that never change state.
mkdir -p "${work_dir}/bin"
cat > "${work_dir}/bin/az" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

sites_json() {
  local kind="$1"
  jq -R -s --arg kind "${kind}" '
    split("\n") | map(select(length > 0) | split("\t"))
    | map(select(.[2] == $kind) | {
        resourceGroup: .[0],
        name: .[1],
        state: .[3],
        id: ("/subscriptions/sub/resourceGroups/" + .[0] + "/providers/Microsoft.Web/sites/" + .[1])
      })' "${FAKE_STATE}"
}

case "$1 $2" in
  "webapp list")
    sites_json webapp
    ;;
  "functionapp list")
    sites_json functionapp
    ;;
  "webapp stop"|"webapp start")
    echo "$*" >> "${FAKE_LOG}"
    name="${4##*/}"
    if [[ "${FAKE_AZ_SCENARIO:-}" == "throttle" && ! -f "${FAKE_STATE}.throttled" ]]; then
      touch "${FAKE_STATE}.throttled"
      echo '{"Code":"429","Message":"Too many requests"}' >&2
      exit 1
    fi
    if [[ "${FAKE_AZ_SCENARIO:-}" == "fail" ]]; then
      echo "boom" >&2
      exit 1
    fi
    [[ "${FAKE_AZ_SCENARIO:-}" == "stuck" ]] && exit 0
    state="Stopped"
    [[ "$2" == "start" ]] && state="Running"
    awk -F'\t' -v OFS='\t' -v name="${name}" -v state="${state}" '$2 == name { $4 = state } { print }' \
      "${FAKE_STATE}" > "${FAKE_STATE}.new"
    mv "${FAKE_STATE}.new" "${FAKE_STATE}"
    ;;
  *)
    echo "unexpected az call: $*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "${work_dir}/bin/az"

write_state() {
  local case_dir="$1"
  mkdir -p "${case_dir}"
  printf '%s\n' \
    $'rg-a\tweb-running\twebapp\tRunning' \
    $'rg-a\tweb-stopped\twebapp\tStopped' \
    $'rg-b\tfunc-running\tfunctionapp\tRunning' \
    $'rg-b\tfunc-stopped\tfunctionapp\tStopped' \
    $'rg-b\tnot-listed\twebapp\tRunning' \
    > "${case_dir}/state"
}

write_apps() {
  local case_dir="$1"
  shift
  mkdir -p "${case_dir}"
  printf '%s\n' "$@" > "${case_dir}/apps.txt"
}

default_apps() {
  write_apps "$1" \
    "# Listed apps" \
    "rg-a/web-running" \
    "RG-A/web-stopped   # mixed case" \
    "" \
    "rg-b/func-running" \
    "rg-b/func-stopped"
}

# Runs the script for a case and prints its exit code
run_case() {
  local case_name="$1"
  local action="$2"
  shift 2
  local case_dir="${work_dir}/${case_name}"
  : > "${case_dir}/log"

  env PATH="${work_dir}/bin:${PATH}" \
    FAKE_STATE="${case_dir}/state" FAKE_LOG="${case_dir}/log" \
    ENVIRONMENT=snd SUBSCRIPTION_NAME=AZR-SND \
    APPS_FILE="${case_dir}/apps.txt" \
    PARALLEL_JOBS=1 THROTTLE_DELAY_SECONDS=0 VERIFY_ATTEMPTS=2 VERIFY_DELAY_SECONDS=0 \
    "$@" bash "${script_path}" "${action}" > "${case_dir}/stdout" 2> "${case_dir}/stderr"
  echo $?
}

calls() {
  sed -E 's#--ids /subscriptions/sub/resourceGroups/[^/]+/providers/Microsoft.Web/sites/##' "${work_dir}/$1/log" | sort
}

state_of() {
  awk -F'\t' -v name="$2" '$2 == name { print $4 }' "${work_dir}/$1/state"
}

# Disable stops only the running listed apps.
case_name="disable"
write_state "${work_dir}/${case_name}"
default_apps "${work_dir}/${case_name}"
exit_code="$(run_case "${case_name}" disable)"
check "disable: exit code" "0" "${exit_code}"
check "disable: stops running listed apps" \
  $'webapp stop func-running --output none\nwebapp stop web-running --output none' \
  "$(calls "${case_name}")"
check "disable: unlisted app keeps running" "Running" "$(state_of "${case_name}" not-listed)"
check "disable: logs already stopped" "2" "$(grep -c "is already stopped" "${work_dir}/${case_name}/stdout")"
check "disable: summary" "1" "$(grep -c "Summary: 2 changed, 2 already stopped, 0 failed" "${work_dir}/${case_name}/stdout")"

# Recover starts only the stopped listed apps.
case_name="recover"
write_state "${work_dir}/${case_name}"
default_apps "${work_dir}/${case_name}"
exit_code="$(run_case "${case_name}" recover)"
check "recover: exit code" "0" "${exit_code}"
check "recover: starts stopped listed apps" \
  $'webapp start func-stopped --output none\nwebapp start web-stopped --output none' \
  "$(calls "${case_name}")"
check "recover: everything listed is running" "Running Running Running Running" \
  "$(for app in web-running web-stopped func-running func-stopped; do state_of "${case_name}" "${app}"; done | xargs)"

# A missing app fails before anything changes.
case_name="missing"
write_state "${work_dir}/${case_name}"
write_apps "${work_dir}/${case_name}" "rg-a/web-running" "rg-a/gone" "rg-b/web-running"
exit_code="$(run_case "${case_name}" disable)"
check "missing: exit code" "1" "${exit_code}"
check "missing: no changes" "" "$(calls "${case_name}")"
check "missing: names every missing app" "2" "$(grep -cE "^  rg-(a/gone|b/web-running)$" "${work_dir}/${case_name}/stdout")"

# Throttling is retried.
case_name="throttle"
write_state "${work_dir}/${case_name}"
write_apps "${work_dir}/${case_name}" "rg-a/web-running"
exit_code="$(run_case "${case_name}" disable FAKE_AZ_SCENARIO=throttle)"
check "throttle: exit code" "0" "${exit_code}"
check "throttle: retried" "2" "$(calls "${case_name}" | wc -l | tr -d ' ')"
check "throttle: app stopped" "Stopped" "$(state_of "${case_name}" web-running)"

# A failed stop fails the run.
case_name="fail"
write_state "${work_dir}/${case_name}"
write_apps "${work_dir}/${case_name}" "rg-a/web-running"
exit_code="$(run_case "${case_name}" disable FAKE_AZ_SCENARIO=fail)"
check "fail: exit code" "1" "${exit_code}"
check "fail: summary" "1" "$(grep -c "Summary: 1 changed, 0 already stopped, 1 failed" "${work_dir}/${case_name}/stdout")"

# An app that never reaches the target state fails verification.
case_name="stuck"
write_state "${work_dir}/${case_name}"
write_apps "${work_dir}/${case_name}" "rg-a/web-running"
exit_code="$(run_case "${case_name}" disable FAKE_AZ_SCENARIO=stuck)"
check "stuck: exit code" "1" "${exit_code}"
check "stuck: names the app" "1" "$(grep -c "^  rg-a/web-running (Running)$" "${work_dir}/${case_name}/stdout")"

# Bad lists fail before anything changes.
for bad in "empty" "bad-line" "duplicate"; do
  case_name="list-${bad}"
  write_state "${work_dir}/${case_name}"
  case "${bad}" in
    empty) write_apps "${work_dir}/${case_name}" "# nothing yet" "" ;;
    bad-line) write_apps "${work_dir}/${case_name}" "web-running" ;;
    duplicate) write_apps "${work_dir}/${case_name}" "rg-a/web-running" "RG-A/Web-Running" ;;
  esac
  exit_code="$(run_case "${case_name}" disable)"
  check "${case_name}: exit code" "1" "${exit_code}"
  check "${case_name}: no changes" "" "$(calls "${case_name}")"
done

# Bad action and environment fail.
case_name="bad-action"
write_state "${work_dir}/${case_name}"
default_apps "${work_dir}/${case_name}"
check "bad-action: exit code" "1" "$(run_case "${case_name}" delete)"
case_name="bad-env"
write_state "${work_dir}/${case_name}"
default_apps "${work_dir}/${case_name}"
check "bad-env: exit code" "1" "$(run_case "${case_name}" disable ENVIRONMENT=dev)"

if [[ "${failures}" -gt 0 ]]; then
  echo "${failures} check(s) failed"
  exit 1
fi
echo "All checks passed"
