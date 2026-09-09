#!/usr/bin/env bash

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/create-identity.sh"
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

  check "${name}" "true" "$(grep -qF "${expected}" "${case_output}" && printf true || printf false)"
}

count_calls() {
  local pattern="$1"

  grep -cF -- "${pattern}" "${case_az_log}" 2>/dev/null || true
}

fake_bin="${work_dir}/bin"
mkdir -p "${fake_bin}"

cat > "${fake_bin}/az" <<'EOF'
#!/usr/bin/env bash

printf '%s\n' "$*" >> "${FAKE_AZ_LOG}"

if [[ "${1:-}" == "identity" && "${2:-}" == "create" ]]; then
  if [[ "${FAKE_AZ_SCENARIO}" == "properties-identity" ]]; then
    printf '%s\n' '{"properties":{"clientId":"created-client","principalId":"created-principal"}}'
  else
    printf '%s\n' '{"clientId":"created-client","principalId":"created-principal"}'
  fi
  exit 0
fi

if [[ "${1:-}" == "identity" && "${2:-}" == "federated-credential" && "${3:-}" == "show" ]]; then
  case "${FAKE_AZ_SCENARIO}" in
    credential-missing)
      echo 'ResourceNotFound: federated credential was not found' >&2
      exit 3
      ;;
    issuer-drift)
      printf '%s\n' '{"issuer":"https://old.example","subject":"system:serviceaccount:tst:alpha-service","audiences":["api://AzureADTokenExchange"]}'
      ;;
    subject-drift)
      printf '%s\n' '{"issuer":"https://issuer.example","subject":"old-subject","audiences":["api://AzureADTokenExchange"]}'
      ;;
    audience-drift)
      printf '%s\n' '{"issuer":"https://issuer.example","subject":"system:serviceaccount:tst:alpha-service","audiences":["old-audience"]}'
      ;;
    properties-credential)
      printf '%s\n' '{"properties":{"issuer":"https://issuer.example","subject":"system:serviceaccount:tst:alpha-service","audiences":["api://AzureADTokenExchange"]}}'
      ;;
    malformed-credential)
      printf '%s\n' 'not-json'
      ;;
    credential-lookup-failure)
      echo 'Forbidden: credential cannot be read' >&2
      exit 1
      ;;
    *)
      printf '%s\n' '{"issuer":"https://issuer.example","subject":"system:serviceaccount:tst:alpha-service","audiences":["api://AzureADTokenExchange"]}'
      ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "identity" && "${2:-}" == "federated-credential" && "${3:-}" == "create" ]]; then
  if [[ "${FAKE_AZ_SCENARIO}" == "retry-create" ]]; then
    attempt=0
    if [[ -f "${FAKE_AZ_STATE}" ]]; then
      attempt="$(cat "${FAKE_AZ_STATE}")"
    fi
    attempt=$((attempt + 1))
    printf '%s\n' "${attempt}" > "${FAKE_AZ_STATE}"
    if [[ "${attempt}" -eq 1 ]]; then
      echo 'ResourceNotFound: identity has not propagated' >&2
      exit 1
    fi
  elif [[ "${FAKE_AZ_SCENARIO}" == "create-failure" ]]; then
    echo 'Forbidden: create is not permitted' >&2
    exit 9
  fi
  exit 0
fi

echo "Unexpected az invocation: $*" >&2
exit 99
EOF

cat > "${fake_bin}/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_SLEEP_LOG}"
EOF

chmod +x "${fake_bin}/az" "${fake_bin}/sleep"

run_case() {
  local case_name="$1"
  local scenario="$2"
  local prefetch_mode="${3:-none}"
  local case_root="${work_dir}/${case_name}"

  mkdir -p "${case_root}"
  case_output="${case_root}/output.log"
  case_az_log="${case_root}/az.log"
  case_sleep_log="${case_root}/sleep.log"
  case_output_file="${case_root}/identity.env"
  case_state="${case_root}/state"
  : > "${case_az_log}"
  : > "${case_sleep_log}"

  (
    export PATH="${fake_bin}:${PATH}"
    export SUBSCRIPTION_NAME="test-subscription"
    export RESOURCE_GROUP_NAME="TST-IMP-RG"
    export MANAGED_IDENTITY_NAME="tst-imp-rg-tst-alpha-service"
    export AKS_CREDENTIAL="alpha-service"
    export AKS_ISSUER="https://issuer.example"
    export AKS_AUDIENCES="api://AzureADTokenExchange"
    export AKS_SUBJECT="system:serviceaccount:tst:alpha-service"
    export CREATE_IDENTITY_OUTPUT_FILE="${case_output_file}"
    export FAKE_AZ_SCENARIO="${scenario}"
    export FAKE_AZ_LOG="${case_az_log}"
    export FAKE_AZ_STATE="${case_state}"
    export FAKE_SLEEP_LOG="${case_sleep_log}"
    unset PREFETCHED_IDENTITY_CLIENT_ID PREFETCHED_IDENTITY_PRINCIPAL_ID

    case "${prefetch_mode}" in
      complete)
        export PREFETCHED_IDENTITY_CLIENT_ID="existing-client"
        export PREFETCHED_IDENTITY_PRINCIPAL_ID="existing-principal"
        ;;
      client-only)
        export PREFETCHED_IDENTITY_CLIENT_ID="existing-client"
        ;;
    esac

    bash "${script_path}"
  ) > "${case_output}" 2>&1
  case_status=$?
}

run_case "matching" matching complete
check "matching state succeeds" "0" "${case_status}"
check "matching state skips identity create" "0" "$(count_calls 'identity create')"
check "matching state checks the credential" "1" "$(count_calls 'identity federated-credential show')"
check "matching state skips credential create" "0" "$(count_calls 'identity federated-credential create')"
check_output_contains "matching state reports the identity skip" "already exists; skipping create"
check_output_contains "matching state reports the credential skip" "already matches"
# shellcheck disable=SC1090
source "${case_output_file}"
check "matching state preserves the cached client ID" "existing-client" "${CLIENT_ID}"
check "matching state preserves the cached principal ID" "existing-principal" "${PRINCIPAL_ID}"

run_case "direct-caller" matching none
check "direct caller succeeds" "0" "${case_status}"
check "direct caller keeps identity create" "1" "$(count_calls 'identity create')"
check "direct caller does not add a credential lookup" "0" "$(count_calls 'identity federated-credential show')"
check "direct caller keeps credential create" "1" "$(count_calls 'identity federated-credential create')"

run_case "properties-identity" properties-identity none
check "properties identity response succeeds" "0" "${case_status}"
# shellcheck disable=SC1090
source "${case_output_file}"
check "properties identity response resolves client ID" "created-client" "${CLIENT_ID}"
check "properties identity response resolves principal ID" "created-principal" "${PRINCIPAL_ID}"

run_case "properties-credential" properties-credential complete
check "properties credential response succeeds" "0" "${case_status}"
check "properties credential response is treated as matching" "0" "$(count_calls 'identity federated-credential create')"

for drift_scenario in issuer-drift subject-drift audience-drift; do
  run_case "${drift_scenario}" "${drift_scenario}" complete
  check "${drift_scenario} succeeds" "0" "${case_status}"
  check "${drift_scenario} updates the credential" "1" "$(count_calls 'identity federated-credential create')"
done

run_case "credential-missing" credential-missing complete
check "missing credential succeeds" "0" "${case_status}"
check "missing credential is created" "1" "$(count_calls 'identity federated-credential create')"

run_case "credential-lookup-failure" credential-lookup-failure complete
check "credential lookup failure falls back successfully" "0" "${case_status}"
check "credential lookup failure uses create/update" "1" "$(count_calls 'identity federated-credential create')"
check_output_contains "credential lookup failure explains fallback" "continuing with the existing create/update path"

run_case "malformed-credential" malformed-credential complete
check "malformed credential response falls back successfully" "0" "${case_status}"
check "malformed credential response uses create/update" "1" "$(count_calls 'identity federated-credential create')"

run_case "incomplete-prefetch" matching client-only
check "incomplete prefetch falls back successfully" "0" "${case_status}"
check "incomplete prefetch uses identity create" "1" "$(count_calls 'identity create')"
check "incomplete prefetch avoids credential show" "0" "$(count_calls 'identity federated-credential show')"
check_output_contains "incomplete prefetch explains fallback" "Ignoring incomplete prefetched identity data"

run_case "retry-create" retry-create none
check "retryable credential create succeeds" "0" "${case_status}"
check "retryable credential create makes two attempts" "2" "$(count_calls 'identity federated-credential create')"
check "retryable credential create sleeps once" "1" "$(wc -l < "${case_sleep_log}" | tr -d ' ')"

run_case "create-failure" create-failure none
check "non-retryable credential create preserves exit status" "9" "${case_status}"
check "non-retryable credential create is not retried" "1" "$(count_calls 'identity federated-credential create')"
check "non-retryable credential create does not sleep" "0" "$(wc -l < "${case_sleep_log}" | tr -d ' ')"

if [[ "${failures}" -gt 0 ]]; then
  echo "${failures} test(s) failed"
  exit 1
fi

echo "all tests passed"
