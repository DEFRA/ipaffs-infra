#!/usr/bin/env bash

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/wait-for-aso-identities-from-services.sh"
work_dir="$(mktemp -d)"

# Invoked by the EXIT trap below.
# shellcheck disable=SC2329
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

  check "${name}" \
    "true" \
    "$(grep -qF "${expected}" "${case_output}" && printf true || printf false)"
}

check_output_excludes() {
  local name="$1"
  local unexpected="$2"

  check "${name}" \
    "true" \
    "$(! grep -qF "${unexpected}" "${case_output}" && printf true || printf false)"
}

count_calls() {
  local pattern="$1"

  grep -c -- "${pattern}" "${case_kubectl_log}" 2>/dev/null || true
}

write_services() {
  local services_root="$1"

  mkdir -p "${services_root}/alpha" "${services_root}/beta"
  cat > "${services_root}/alpha/base.yaml" <<'EOF'
database:
  migrations:
    enabled: true
EOF
  cat > "${services_root}/beta/base.yaml" <<'EOF'
database:
  migrations:
    enabled: false
EOF
}

fake_bin="${work_dir}/bin"
mkdir -p "${fake_bin}"

cat > "${fake_bin}/yq" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
  values_file="${argument}"
done

if grep -q 'enabled: true' "${values_file}"; then
  printf 'true\n'
else
  printf 'false\n'
fi
EOF

cat > "${fake_bin}/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_SLEEP_LOG}"
EOF

cat > "${fake_bin}/kubectl" <<'EOF'
#!/usr/bin/env bash

printf '%s\n' "$*" >> "${FAKE_KUBECTL_LOG}"

if [[ "${3:-}" != "--namespace" ]]; then
  if [[ "$*" == *'--output yaml'* ]]; then
    printf 'metadata:\n  name: %s\n' "${3}"
  else
    printf 'client-id\n'
  fi
  exit 0
fi

count=0
if [[ -f "${FAKE_KUBECTL_STATE}" ]]; then
  count="$(cat "${FAKE_KUBECTL_STATE}")"
fi
count=$((count + 1))
printf '%s\n' "${count}" > "${FAKE_KUBECTL_STATE}"

all_ready='{
  "items": [
    {"metadata":{"name":"tst-imp-rg-tst-alpha-service"},"status":{"clientId":"alpha-service-id"}},
    {"metadata":{"name":"tst-imp-rg-tst-alpha-migrations"},"status":{"clientId":"alpha-migrations-id"}},
    {"metadata":{"name":"tst-imp-rg-tst-beta-service"},"status":{"clientId":"beta-service-id"}},
    {"metadata":{"name":"unrelated-identity"},"status":{"clientId":"unrelated-id"}}
  ]
}'

case "${FAKE_KUBECTL_SCENARIO}" in
  all-ready)
    printf '%s\n' "${all_ready}"
    ;;
  delayed)
    if [[ "${count}" -eq 1 ]]; then
      printf '%s\n' '{"items":[
        {"metadata":{"name":"tst-imp-rg-tst-alpha-service"},"status":{"clientId":"alpha-service-id"}},
        {"metadata":{"name":"tst-imp-rg-tst-beta-service"},"status":{}}
      ]}'
    else
      printf '%s\n' "${all_ready}"
    fi
    ;;
  timeout)
    printf '%s\n' '{"items":[
      {"metadata":{"name":"tst-imp-rg-tst-alpha-service"},"status":{"clientId":"alpha-service-id"}},
      {"metadata":{"name":"tst-imp-rg-tst-beta-service"},"status":{}}
    ]}'
    ;;
  list-failure)
    echo 'Error from server (Forbidden): identities cannot be listed' >&2
    exit 1
    ;;
  malformed)
    printf 'not-json\n'
    ;;
  *)
    echo "Unknown fake kubectl scenario: ${FAKE_KUBECTL_SCENARIO}" >&2
    exit 1
    ;;
esac
EOF

chmod +x "${fake_bin}/kubectl" "${fake_bin}/sleep" "${fake_bin}/yq"

run_case() {
  local case_name="$1"
  local scenario="$2"
  local mode="$3"
  local timeout="${4:-2}"
  local interval="${5:-1}"
  local case_root="${work_dir}/${case_name}"
  local services_root="${case_root}/services"

  mkdir -p "${case_root}"
  write_services "${services_root}"

  case_output="${case_root}/output.log"
  case_kubectl_log="${case_root}/kubectl.log"
  case_sleep_log="${case_root}/sleep.log"
  case_state="${case_root}/kubectl-state"
  : > "${case_kubectl_log}"
  : > "${case_sleep_log}"

  if [[ "${mode}" == "unset" ]]; then
    if PATH="${fake_bin}:${PATH}" \
      NAMESPACE=tst \
      RESOURCE_GROUP_NAME=TST-IMP-RG \
      SERVICES_ROOT="${services_root}" \
      WAIT_TIMEOUT_SECONDS="${timeout}" \
      WAIT_INTERVAL_SECONDS="${interval}" \
      FAKE_KUBECTL_SCENARIO="${scenario}" \
      FAKE_KUBECTL_LOG="${case_kubectl_log}" \
      FAKE_KUBECTL_STATE="${case_state}" \
      FAKE_SLEEP_LOG="${case_sleep_log}" \
      bash "${script_path}" > "${case_output}" 2>&1; then
      case_status=0
    else
      case_status=$?
    fi
  else
    if PATH="${fake_bin}:${PATH}" \
      NAMESPACE=tst \
      RESOURCE_GROUP_NAME=TST-IMP-RG \
      SERVICES_ROOT="${services_root}" \
      ASO_IDENTITY_WAIT_MODE="${mode}" \
      WAIT_TIMEOUT_SECONDS="${timeout}" \
      WAIT_INTERVAL_SECONDS="${interval}" \
      FAKE_KUBECTL_SCENARIO="${scenario}" \
      FAKE_KUBECTL_LOG="${case_kubectl_log}" \
      FAKE_KUBECTL_STATE="${case_state}" \
      FAKE_SLEEP_LOG="${case_sleep_log}" \
      bash "${script_path}" > "${case_output}" 2>&1; then
      case_status=0
    else
      case_status=$?
    fi
  fi
}

run_case "default-sequential" all-ready unset
check "the default mode succeeds" "0" "${case_status}"
check "the default mode performs three named reads" "3" "$(count_calls ' jsonpath=')"
check "the default mode performs no collection reads" "0" "$(count_calls '--output json$')"

run_case "batch-ready" all-ready batch
check "batch mode succeeds when every identity is ready" "0" "${case_status}"
check "batch mode performs one collection read" "1" "$(count_calls '--output json$')"
check "batch mode performs no named reads" "0" "$(count_calls ' jsonpath=')"
check "batch mode does not sleep when every identity is ready" "0" "$(wc -l < "${case_sleep_log}" | tr -d ' ')"
check_output_contains "batch mode includes the migrations identity" "ASO clientIds resolved for all 3 identities"
check_output_excludes "batch mode does not log clientIds" "alpha-service-id"

run_case "batch-delayed" delayed batch
check "batch mode succeeds after identities become ready" "0" "${case_status}"
check "batch mode performs one collection read per poll" "2" "$(count_calls '--output json$')"
check "batch mode sleeps once between two polls" "1" "$(wc -l < "${case_sleep_log}" | tr -d ' ')"
check_output_contains "batch mode distinguishes missing resources from pending clientIds" "1 resources not found, 1 clientIds pending"

run_case "batch-timeout" timeout batch
check "batch mode fails after its shared timeout" "1" "${case_status}"
check "batch mode polls twice before a two-second timeout" "2" "$(count_calls '--output json$')"
check_output_contains "timeout reports a missing migration identity" "  - tst-imp-rg-tst-alpha-migrations"
check_output_contains "timeout reports an identity with no clientId" "  - tst-imp-rg-tst-beta-service"

run_case "batch-list-fallback" list-failure batch
check "a failed collection read falls back successfully" "0" "${case_status}"
check "fallback attempts one collection read" "1" "$(count_calls '--output json$')"
check "fallback checks each identity by name" "3" "$(count_calls ' jsonpath=')"
check_output_contains "fallback explains why batching was abandoned" "switching to sequential readiness checks"

run_case "batch-malformed-fallback" malformed batch
check "an invalid collection response falls back successfully" "0" "${case_status}"
check "invalid JSON falls back to three named reads" "3" "$(count_calls ' jsonpath=')"

run_case "invalid-mode" all-ready invalid
check "an invalid mode fails" "1" "${case_status}"
check "an invalid mode fails before calling kubectl" "0" "$(wc -l < "${case_kubectl_log}" | tr -d ' ')"
check_output_contains "an invalid mode is diagnosed" "ASO_IDENTITY_WAIT_MODE must be 'sequential' or 'batch'"

run_case "invalid-interval" all-ready batch 2 0
check "a zero poll interval fails" "1" "${case_status}"
check "a zero poll interval fails before calling kubectl" "0" "$(wc -l < "${case_kubectl_log}" | tr -d ' ')"

empty_case_root="${work_dir}/empty-services"
mkdir -p "${empty_case_root}/services"
printf 'not a service directory\n' > "${empty_case_root}/services/README"
case_output="${empty_case_root}/output.log"
case_kubectl_log="${empty_case_root}/kubectl.log"
: > "${case_kubectl_log}"
if PATH="${fake_bin}:${PATH}" \
  NAMESPACE=tst \
  RESOURCE_GROUP_NAME=TST-IMP-RG \
  SERVICES_ROOT="${empty_case_root}/services" \
  ASO_IDENTITY_WAIT_MODE=batch \
  FAKE_KUBECTL_SCENARIO=all-ready \
  FAKE_KUBECTL_LOG="${case_kubectl_log}" \
  FAKE_KUBECTL_STATE="${empty_case_root}/kubectl-state" \
  FAKE_SLEEP_LOG="${empty_case_root}/sleep.log" \
  bash "${script_path}" > "${case_output}" 2>&1; then
  case_status=0
else
  case_status=$?
fi
check "a services root containing no directories fails" "1" "${case_status}"
check "an empty services root fails before calling kubectl" "0" "$(wc -l < "${case_kubectl_log}" | tr -d ' ')"

if [[ "${failures}" -gt 0 ]]; then
  echo "${failures} test(s) failed"
  exit 1
fi

echo "all tests passed"
