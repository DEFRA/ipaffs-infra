#!/usr/bin/env bash
# Tests scripts/hooks/10-delete-decommissioned-secrets.sh with a fake az on PATH.
# Kept outside scripts/hooks so the hook runner never runs it.

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook_path="${script_dir}/../hooks/10-delete-decommissioned-secrets.sh"
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

contains() {
  grep -qF -- "$2" "$1" && printf true || printf false
}

count_calls() {
  grep -cF -- "$1" "${FAKE_AZ_LOG}" 2>/dev/null || true
}

fake_bin="${work_dir}/bin"
mkdir -p "${fake_bin}"

# FAKE_SECRETS holds the secret names present in the vault, FAKE_AZ_SCENARIO forces failures
cat > "${fake_bin}/az" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_AZ_LOG}"

case "$1 $2" in
  "keyvault show")
    [[ "${FAKE_AZ_SCENARIO:-}" == "no-vault" ]] && { echo "ResourceNotFound" >&2; exit 3; }
    echo "vault"
    ;;
  "keyvault secret")
    case "$3" in
      list)
        [[ "${FAKE_AZ_SCENARIO:-}" == "list-forbidden" ]] && { echo "Forbidden" >&2; exit 1; }
        tr ',' '\n' <<<"${FAKE_SECRETS:-}"
        ;;
      delete)
        if [[ "${FAKE_AZ_SCENARIO:-}" == "delete-forbidden" ]]; then
          echo "Forbidden" >&2
          exit 1
        fi
        ;;
      show)
        echo "the hook must never read secret values" >&2
        exit 99
        ;;
    esac
    ;;
esac
EOF
chmod +x "${fake_bin}/az"

list_file="${work_dir}/secrets.txt"
cat > "${list_file}" <<'EOF'
# a comment

countriesDatabasePassword
  countriesDatabasePasswordNew   # trailing comment
EOF

# run_case <name> <environment> <dry run> <present secrets> [scenario]
run_case() {
  case_dir="${work_dir}/$1"
  mkdir -p "${case_dir}"
  export FAKE_AZ_LOG="${case_dir}/az.log"
  : > "${FAKE_AZ_LOG}"
  case_output="${case_dir}/output.log"

  PATH="${fake_bin}:${PATH}" \
    ENVIRONMENT="$2" DRY_RUN="$3" FAKE_SECRETS="$4" FAKE_AZ_SCENARIO="${5:-}" \
    SUBSCRIPTION_ID="sub-id" DECOMMISSIONED_SECRETS_FILE="${list_file}" \
    bash "${hook_path}" > "${case_output}" 2>&1
  case_status=$?
}

run_case dry-run tst true "countriesDatabasePassword,countriesDatabasePasswordNew,legacyDatabasePassword1"
check "dry run exits 0" "0" "${case_status}"
check "dry run uses the environment vault" "true" "$(contains "${FAKE_AZ_LOG}" "keyvault show --name TSTIMPINFKV1401 --subscription sub-id")"
check "dry run reports the first secret" "true" "$(contains "${case_output}" "Would delete countriesDatabasePassword from TSTIMPINFKV1401")"
check "dry run reports the second secret" "true" "$(contains "${case_output}" "Would delete countriesDatabasePasswordNew from TSTIMPINFKV1401")"
check "dry run deletes nothing" "0" "$(count_calls "secret delete")"

run_case real-run prd false "countriesDatabasePassword,countriesDatabasePasswordNew,legacyDatabasePassword1"
check "real run exits 0" "0" "${case_status}"
check "real run deletes the first secret" "1" "$(count_calls "secret delete --vault-name PRDIMPINFKV1401 --subscription sub-id --name countriesDatabasePassword -o none")"
check "real run deletes the second secret" "1" "$(count_calls "secret delete --vault-name PRDIMPINFKV1401 --subscription sub-id --name countriesDatabasePasswordNew -o none")"
check "real run deletes only listed secrets" "2" "$(count_calls "secret delete")"
check "real run never touches shared secrets" "0" "$(count_calls "legacyDatabasePassword1")"
check "real run never purges" "0" "$(count_calls "purge")"
check "real run never reads values" "0" "$(count_calls "secret show")"

run_case absent dev false "legacyDatabasePassword1,legacyDatabasePassword2"
check "absent secrets exit 0" "0" "${case_status}"
check "absent secrets are reported" "true" "$(contains "${case_output}" "countriesDatabasePassword is already absent from DEVIMPINFKV1401")"
check "absent secrets are not deleted" "0" "$(count_calls "secret delete")"

run_case partly-deleted pre false "countriesDatabasePasswordNew"
check "second run exits 0" "0" "${case_status}"
check "second run deletes only what is left" "1" "$(count_calls "secret delete")"
check "second run skips the deleted secret" "true" "$(contains "${case_output}" "countriesDatabasePassword is already absent from PREIMPINFKV1401")"

run_case no-vault tst false "countriesDatabasePassword" no-vault
check "missing vault fails" "1" "${case_status}"
check "missing vault explains why" "true" "$(contains "${case_output}" "Key Vault TSTIMPINFKV1401 was not found or cannot be read")"
check "missing vault deletes nothing" "0" "$(count_calls "secret delete")"

run_case list-forbidden tst false "countriesDatabasePassword" list-forbidden
check "list failure fails" "1" "${case_status}"
check "list failure deletes nothing" "0" "$(count_calls "secret delete")"

run_case delete-forbidden tst false "countriesDatabasePassword,countriesDatabasePasswordNew" delete-forbidden
check "delete failure fails" "1" "${case_status}"
check "delete failure explains why" "true" "$(contains "${case_output}" "Could not delete countriesDatabasePassword from TSTIMPINFKV1401")"
check "delete failure stops at the first secret" "1" "$(count_calls "secret delete")"

empty_list="${work_dir}/empty.txt"
printf '# nothing listed\n\n' > "${empty_list}"
export FAKE_AZ_LOG="${work_dir}/empty-az.log"
: > "${FAKE_AZ_LOG}"
PATH="${fake_bin}:${PATH}" ENVIRONMENT=tst DRY_RUN=false DECOMMISSIONED_SECRETS_FILE="${empty_list}" \
  bash "${hook_path}" > /dev/null 2>&1
check "empty list exits 0" "0" "$?"
check "empty list calls nothing" "0" "$(count_calls "keyvault")"

PATH="${fake_bin}:${PATH}" ENVIRONMENT=tst DECOMMISSIONED_SECRETS_FILE="${work_dir}/missing.txt" \
  bash "${hook_path}" > /dev/null 2>&1
check "missing list fails" "1" "$?"

PATH="${fake_bin}:${PATH}" ENVIRONMENT=tst \
  bash "${hook_path}" > "${work_dir}/default.log" 2>&1
check "default list is the committed one" "true" "$(contains "${work_dir}/default.log" "Checking 2 decommissioned secret(s) in TSTIMPINFKV1401 (DryRun=true)")"

if [[ ${failures} -gt 0 ]]; then
  echo "${failures} check(s) failed"
  exit 1
fi

echo "All checks passed"
