#!/usr/bin/env bash
#
# validator.test.sh
# Offline unit tests for the pure helpers in validator.sh. No Azure, no network.
# Fixtures use placeholder names only - no real vault, service or App Service names.
# Usage: ./validator.test.sh

set -uo pipefail

cd "$(dirname "${0}")"
# shellcheck source=/dev/null
source ./validator.sh
set +e   # validator.sh turns on -e; a failing assertion must not abort the run

failures=0
work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

check() {
  local name="${1}" expected="${2}" actual="${3}"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "ok   - ${name}"
  else
    echo "FAIL - ${name}: expected '${expected}' but got '${actual}'"
    failures=$((failures + 1))
  fi
}

# Run a command and report yes/no rather than an exit status.
yes_no() {
  if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi
}

# -- app_service_base --

ENVIRONMENT=tst

check "blue slot and environment are stripped" \
  "example-microservice" "$(app_service_base example-microservice-blue-tst)"

check "green slot and environment are stripped" \
  "example-microservice" "$(app_service_base example-microservice-green-tst)"

check "a single-slot App Service strips only the environment" \
  "example" "$(app_service_base example-tst)"

# -- sec_secret_suffix --

check "AZURE_SEARCH_DB_PASSWORD suffix has no postfix" \
  "AzureSearchDatabasePassword" "$(sec_secret_suffix AZURE_SEARCH_DB_PASSWORD)"

check "BASE_SERVICE_DB_PASSWORD suffix has no postfix" \
  "DatabasePassword" "$(sec_secret_suffix BASE_SERVICE_DB_PASSWORD)"

check "NEW_BASE_SERVICE_DB_PASSWORD suffix carries the -<env> postfix" \
  "DatabasePassword-tst" "$(sec_secret_suffix NEW_BASE_SERVICE_DB_PASSWORD)"

check "an unlisted secretKey is not SEC-derived" \
  no "$(yes_no sec_secret_suffix SOME_OTHER_SECRET)"

ENVIRONMENT=prd
check "the full derived key follows the environment" \
  "example-microserviceDatabasePassword-prd" \
  "$(app_service_base example-microservice-prd)$(sec_secret_suffix NEW_BASE_SERVICE_DB_PASSWORD)"
ENVIRONMENT=tst

# -- resource_group_for / resource_kind_for --
# Columns are name, resourceGroup, kind - the order az resource list emits.
# The kind decides whether check_app_service asks az webapp or az functionapp.

APP_SITES_TSV="$(printf '%s\t%s\t%s\n%s\t%s\t%s\n' \
  example-microservice-blue-tst RG-EXAMPLE 'app,linux' \
  example-function-tst          RG-EXAMPLE 'functionapp,linux')"

check "resource group is found by App Service name" \
  "RG-EXAMPLE" "$(resource_group_for example-microservice-blue-tst)"

check "a web app reports an app kind" \
  "app,linux" "$(resource_kind_for example-microservice-blue-tst)"

check "a function app reports a functionapp kind" \
  "functionapp,linux" "$(resource_kind_for example-function-tst)"

check "an unknown App Service has no resource group" \
  "" "$(resource_group_for not-mapped-tst)"

check "an unknown App Service has no kind" \
  "" "$(resource_kind_for not-mapped-tst)"

# -- resolve_app_services --

SERVICE_MAPPING_FILE="${work_dir}/mapping.txt"
cat > "${SERVICE_MAPPING_FILE}" <<'EOF'
# comments and blank lines are ignored

example-service|example-microservice-blue-tst
example-service|example-microservice-green-tst
other-service|other-microservice-tst
EOF

check "every mapped slot is returned" \
  "example-microservice-blue-tst,example-microservice-green-tst" \
  "$(resolve_app_services example-service | tr '\n' ',' | sed 's/,$//')"

check "a service with no mapping returns nothing" \
  "" "$(resolve_app_services unmapped-service)"

# -- app_setting / has_app_setting --
# check_config relies on telling "set but empty" apart from "not set at all".

APP_SETTINGS_JSON='[{"name":"PLAIN","value":"hello"},{"name":"EMPTY","value":""}]'

check "an app setting value is returned" "hello" "$(app_setting PLAIN)"
check "a missing app setting is empty"   ""      "$(app_setting NOPE)"
check "a present but empty setting exists" yes "$(yes_no has_app_setting EMPTY)"
check "a missing setting does not exist"   no  "$(yes_no has_app_setting NOPE)"

# -- parse_ref_field --

reference='@Microsoft.KeyVault(VaultName=EXAMPLEVAULT001;SecretName=example-microserviceDatabasePassword)'

check "vault name is parsed from a reference" \
  "EXAMPLEVAULT001" "$(parse_ref_field "${reference}" VaultName)"

check "secret name is parsed from a reference" \
  "example-microserviceDatabasePassword" "$(parse_ref_field "${reference}" SecretName)"

check "a malformed reference yields nothing" \
  "" "$(parse_ref_field '@Microsoft.KeyVault(VaultName=EXAMPLEVAULT001)' SecretName)"

# -- csv_row --

CSV_FILE="${work_dir}/out.csv"

csv_row MATCH 'svc,with,commas' 'app "quoted"' plain
check "csv fields with commas and quotes are escaped" \
  'MATCH,"svc,with,commas","app ""quoted""",plain' \
  "$(cat "${CSV_FILE}")"

if [[ "${failures}" -gt 0 ]]; then
  echo "${failures} test(s) failed"
  exit 1
fi
echo "all tests passed"
