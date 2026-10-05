#!/usr/bin/env bash

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/run-hooks.sh"
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

# Each hook appends its name and the inherited env to a log so order and
# substitution can be asserted.
write_hook() {
  local path="$1"
  local label="$2"
  local exit_code="${3:-0}"

  mkdir -p "$(dirname "${path}")"
  cat > "${path}" <<HOOK
#!/usr/bin/env bash
echo "${label} env=\${ENVIRONMENT} dry=\${DRY_RUN}" >> "\${HOOK_LOG}"
exit ${exit_code}
HOOK
}

hook_log() {
  echo "${work_dir}/$1/log"
}

run_hooks() {
  local case_name="$1"
  shift
  local case_dir="${work_dir}/${case_name}"
  : > "$(hook_log "${case_name}")"

  env HOOKS_DIR="${case_dir}/hooks" HOOK_LOG="$(hook_log "${case_name}")" "$@" \
    bash "${script_path}" > "${case_dir}/stdout" 2> "${case_dir}/stderr"
  echo $?
}

# Common hooks run in lexical filename order.
case_name="order"
hooks="${work_dir}/${case_name}/hooks"
write_hook "${hooks}/20-second.sh" second
write_hook "${hooks}/10-first.sh" first
write_hook "${hooks}/30-third.sh" third
exit_code="$(run_hooks "${case_name}" ENVIRONMENT=dev DRY_RUN=true)"
check "order: exit code" "0" "${exit_code}"
check "order: hooks run lexically" \
  $'first env=dev dry=true\nsecond env=dev dry=true\nthird env=dev dry=true' \
  "$(cat "$(hook_log "${case_name}")")"

# An environment hook with the same name replaces the common one.
case_name="override"
hooks="${work_dir}/${case_name}/hooks"
write_hook "${hooks}/10-first.sh" common-first
write_hook "${hooks}/20-second.sh" common-second
write_hook "${hooks}/tst/20-second.sh" tst-second
exit_code="$(run_hooks "${case_name}" ENVIRONMENT=tst DRY_RUN=false)"
check "override: exit code" "0" "${exit_code}"
check "override: env hook replaces common hook" \
  $'common-first env=tst dry=false\ntst-second env=tst dry=false' \
  "$(cat "$(hook_log "${case_name}")")"

# An environment-only hook is added and sorted into the sequence.
case_name="env-only"
hooks="${work_dir}/${case_name}/hooks"
write_hook "${hooks}/10-first.sh" first
write_hook "${hooks}/30-third.sh" third
write_hook "${hooks}/prd/20-second.sh" prd-second
write_hook "${hooks}/dev/15-dev-only.sh" dev-only
exit_code="$(run_hooks "${case_name}" ENVIRONMENT=prd DRY_RUN=true)"
check "env-only: exit code" "0" "${exit_code}"
check "env-only: hook is merged in order, other envs ignored" \
  $'first env=prd dry=true\nprd-second env=prd dry=true\nthird env=prd dry=true' \
  "$(cat "$(hook_log "${case_name}")")"

# A failing hook stops the run with its exit code; later hooks do not run.
case_name="failure"
hooks="${work_dir}/${case_name}/hooks"
write_hook "${hooks}/10-first.sh" first
write_hook "${hooks}/20-broken.sh" broken 3
write_hook "${hooks}/30-third.sh" third
exit_code="$(run_hooks "${case_name}" ENVIRONMENT=dev DRY_RUN=true)"
check "failure: exit code is the hook's" "3" "${exit_code}"
check "failure: later hooks do not run" \
  $'first env=dev dry=true\nbroken env=dev dry=true' \
  "$(cat "$(hook_log "${case_name}")")"
check "failure: logs an ADO error issue" "1" \
  "$(grep -c '##vso\[task.logissue type=error\]Hook 20-broken.sh failed with exit code 3' "${work_dir}/${case_name}/stdout")"

# Environment name is lower-cased and DRY_RUN defaults to true.
case_name="defaults"
hooks="${work_dir}/${case_name}/hooks"
write_hook "${hooks}/10-first.sh" first
exit_code="$(run_hooks "${case_name}" ENVIRONMENT=PRE)"
check "defaults: exit code" "0" "${exit_code}"
check "defaults: environment lower-cased, dry run on" "first env=pre dry=true" "$(cat "$(hook_log "${case_name}")")"

# An empty hooks directory is not an error.
case_name="empty"
mkdir -p "${work_dir}/${case_name}/hooks"
exit_code="$(run_hooks "${case_name}" ENVIRONMENT=dev)"
check "empty: exit code" "0" "${exit_code}"
check "empty: nothing ran" "" "$(cat "$(hook_log "${case_name}")")"

# Bad inputs fail before any hook runs.
case_name="bad-dry-run"
hooks="${work_dir}/${case_name}/hooks"
write_hook "${hooks}/10-first.sh" first
exit_code="$(run_hooks "${case_name}" ENVIRONMENT=dev DRY_RUN=maybe)"
check "bad-dry-run: exit code" "1" "${exit_code}"
check "bad-dry-run: no hook ran" "" "$(cat "$(hook_log "${case_name}")")"

case_name="bad-environment"
hooks="${work_dir}/${case_name}/hooks"
write_hook "${hooks}/10-first.sh" first
exit_code="$(run_hooks "${case_name}" ENVIRONMENT=snd)"
check "bad-environment: exit code" "1" "${exit_code}"
check "bad-environment: no hook ran" "" "$(cat "$(hook_log "${case_name}")")"

case_name="missing-dir"
mkdir -p "${work_dir}/${case_name}"
exit_code="$(run_hooks "${case_name}" ENVIRONMENT=dev)"
check "missing-dir: exit code" "1" "${exit_code}"

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} check(s) failed"
  exit 1
fi

echo "All checks passed"
