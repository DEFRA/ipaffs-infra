#!/usr/bin/env bash

set -uo pipefail

source_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

argument_value() {
  local requested_name="$1"
  shift

  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "${requested_name}" ]]; then
      printf '%s\n' "${2:-}"
      return
    fi
    shift
  done
}

if [[ "${1:-}" == "identity" && "${2:-}" == "list" ]]; then
  case "${FAKE_AZ_SCENARIO}" in
    list-failure)
      echo 'Forbidden: identities cannot be listed' >&2
      exit 1
      ;;
    malformed-list)
      printf '%s\n' '{"unexpected":true}'
      exit 0
      ;;
    null-id)
      printf '%s\n' '[
        {"name":"TST-IMP-RG-TST-ALPHA-SERVICE","clientId":"alpha-service-client","principalId":null},
        {"name":"tst-imp-rg-tst-alpha-migrations","properties":{"clientId":"alpha-migrations-client","principalId":"alpha-migrations-principal"}},
        {"name":"tst-imp-rg-tst-beta-service","clientId":"beta-service-client","principalId":"beta-service-principal"}
      ]'
      exit 0
      ;;
    *)
      printf '%s\n' '[
        {"name":"TST-IMP-RG-TST-ALPHA-SERVICE","clientId":"alpha-service-client","principalId":"alpha-service-principal"},
        {"name":"tst-imp-rg-tst-alpha-migrations","properties":{"clientId":"alpha-migrations-client","principalId":"alpha-migrations-principal"}},
        {"name":"tst-imp-rg-tst-beta-service","clientId":"beta-service-client","principalId":"beta-service-principal"}
      ]'
      exit 0
      ;;
  esac
fi

if [[ "${1:-}" == "identity" && "${2:-}" == "create" ]]; then
  identity_name="$(argument_value --name "$@")"
  printf '{"clientId":"created-%s-client","principalId":"created-%s-principal"}\n' "${identity_name}" "${identity_name}"
  exit 0
fi

if [[ "${1:-}" == "identity" && "${2:-}" == "federated-credential" && "${3:-}" == "show" ]]; then
  jq -nc \
    --arg issuer "${AKS_ISSUER}" \
    --arg subject "${AKS_SUBJECT}" \
    --arg audience "${AKS_AUDIENCES}" \
    '{issuer:$issuer,subject:$subject,audiences:[$audience]}'
  exit 0
fi

if [[ "${1:-}" == "identity" && "${2:-}" == "federated-credential" && "${3:-}" == "create" ]]; then
  exit 0
fi

echo "Unexpected az invocation: $*" >&2
exit 99
EOF

chmod +x "${fake_bin}/az"

write_test_scripts() {
  local scripts_dir="$1"

  mkdir -p "${scripts_dir}"
  cp "${source_script_dir}/deploy-identities-from-services.sh" "${scripts_dir}/"
  cp "${source_script_dir}/create-identity.sh" "${scripts_dir}/"

  cat > "${scripts_dir}/add-entra-group-members.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "${GROUP_ID}" "${GROUP_MEMBERS}" >> "${FAKE_GROUP_LOG}"
EOF

  cat > "${scripts_dir}/wait-for-group-memberships.sh" <<'EOF'
#!/usr/bin/env bash
echo 'Membership verification should not run in this test' >&2
exit 98
EOF

  chmod +x "${scripts_dir}"/*.sh
}

write_services() {
  local services_root="$1"

  mkdir -p "${services_root}/alpha" "${services_root}/beta"
  printf '%s\n' 'database: {}' > "${services_root}/alpha/base.yaml"
  printf '%s\n' 'database: {}' > "${services_root}/beta/base.yaml"
}

run_case() {
  local case_name="$1"
  local scenario="$2"
  local case_root="${work_dir}/${case_name}"
  local scripts_dir="${case_root}/scripts"
  local services_root="${case_root}/services"

  mkdir -p "${case_root}"
  write_test_scripts "${scripts_dir}"
  write_services "${services_root}"

  case_output="${case_root}/output.log"
  case_az_log="${case_root}/az.log"
  case_group_log="${case_root}/groups.log"
  : > "${case_az_log}"
  : > "${case_group_log}"

  PATH="${fake_bin}:${PATH}" \
    NAMESPACE=tst \
    RESOURCE_GROUP_NAME=TST-IMP-RG \
    SUBSCRIPTION_NAME=test-subscription \
    AKS_ISSUER=https://issuer.example \
    SEARCH_CONTRIBUTORS_GROUP_ID=search-group \
    BLOB_STORAGE_CONTRIBUTORS_GROUP_ID=blob-group \
    SQL_ADMIN_GROUP_ID=sql-group \
    SERVICES_ROOT="${services_root}" \
    MIGRATIONS_ENABLED_SERVICES=alpha \
    FAKE_AZ_SCENARIO="${scenario}" \
    FAKE_AZ_LOG="${case_az_log}" \
    FAKE_GROUP_LOG="${case_group_log}" \
    bash "${scripts_dir}/deploy-identities-from-services.sh" > "${case_output}" 2>&1
  case_status=$?
}

run_case "all-existing" all-existing
check "all-existing deployment succeeds" "0" "${case_status}"
check "all identities are listed once" "1" "$(count_calls 'identity list')"
check "case-insensitive cached identities skip every create" "0" "$(count_calls 'identity create')"
check "each existing credential is checked" "3" "$(count_calls 'identity federated-credential show')"
check "matching credentials skip every write" "0" "$(count_calls 'identity federated-credential create')"
check_output_contains "preload reports three usable identities" "Loaded 3 existing managed identities"
check "cached principal IDs reach group reconciliation" "true" "$(grep -qF 'alpha-service-principal' "${case_group_log}" && grep -qF 'alpha-migrations-principal' "${case_group_log}" && grep -qF 'beta-service-principal' "${case_group_log}" && printf true || printf false)"

run_case "null-id" null-id
check "null-ID deployment succeeds" "0" "${case_status}"
check "null-ID cache entry falls back to one identity create" "1" "$(count_calls 'identity create')"
check "only complete cached identities perform credential reads" "2" "$(count_calls 'identity federated-credential show')"
check "newly reconciled identity creates its credential directly" "1" "$(count_calls 'identity federated-credential create')"
check_output_contains "null-ID preload reports only usable entries" "Loaded 2 existing managed identities"

for fallback_scenario in list-failure malformed-list; do
  run_case "${fallback_scenario}" "${fallback_scenario}"
  check "${fallback_scenario} deployment succeeds" "0" "${case_status}"
  check "${fallback_scenario} attempts one list" "1" "$(count_calls 'identity list')"
  check "${fallback_scenario} restores all identity creates" "3" "$(count_calls 'identity create')"
  check "${fallback_scenario} avoids credential reads" "0" "$(count_calls 'identity federated-credential show')"
  check "${fallback_scenario} restores all credential creates" "3" "$(count_calls 'identity federated-credential create')"
  check_output_contains "${fallback_scenario} explains fallback" "continuing with the existing create/update path"
done

empty_case_root="${work_dir}/empty-services"
empty_scripts_dir="${empty_case_root}/scripts"
empty_services_root="${empty_case_root}/services"
mkdir -p "${empty_services_root}"
write_test_scripts "${empty_scripts_dir}"
case_output="${empty_case_root}/output.log"
case_az_log="${empty_case_root}/az.log"
: > "${case_az_log}"
if PATH="${fake_bin}:${PATH}" \
  NAMESPACE=tst \
  RESOURCE_GROUP_NAME=TST-IMP-RG \
  SUBSCRIPTION_NAME=test-subscription \
  AKS_ISSUER=https://issuer.example \
  SEARCH_CONTRIBUTORS_GROUP_ID=search-group \
  BLOB_STORAGE_CONTRIBUTORS_GROUP_ID=blob-group \
  SQL_ADMIN_GROUP_ID=sql-group \
  SERVICES_ROOT="${empty_services_root}" \
  FAKE_AZ_SCENARIO=all-existing \
  FAKE_AZ_LOG="${case_az_log}" \
  FAKE_GROUP_LOG="${empty_case_root}/groups.log" \
  bash "${empty_scripts_dir}/deploy-identities-from-services.sh" > "${case_output}" 2>&1; then
  case_status=0
else
  case_status=$?
fi
check "empty services root fails" "1" "${case_status}"
check "empty services root fails before listing identities" "0" "$(count_calls 'identity list')"

if [[ "${failures}" -gt 0 ]]; then
  echo "${failures} test(s) failed"
  exit 1
fi

echo "all tests passed"
