#!/usr/bin/env bash
#
# validator.sh
# Usage:
#   ./validator.sh [--hide-unresolved] [--csv <file>] [config-file]
#   --hide-unresolved - suppress per-service "UNRESOLVED" lines
#   --csv <file>      - also write one row per secret check to <file>
#
# Config: pass a per-environment file to source (e.g. tst.env), or omit it to use
# the current environment.
#
# Requires: az (logged in), jq, yq. Targets bash 3.2 and Git Bash.
# The pure helpers are covered by ./validator.test.sh, which runs without Azure.

set -euo pipefail

HIDE_UNRESOLVED=0
CSV_FILE=""
CONFIG_FILE=""

APP_SETTINGS_JSON=""   # app settings of the App Service currently being checked
APP_SITES_TSV=""       # "name<TAB>resourceGroup" for every site in the subscription

count_checked=0
count_matches=0
count_mismatches=0
count_skipped=0
count_unresolved=0
count_errors=0

REQUIRED_VARS="
SOURCE_VAULT_NAME SOURCE_VAULT_AZCLI_DIR
TARGET_VAULT_NAME TARGET_VAULT_AZCLI_DIR
APP_SERVICE_SUBSCRIPTION
SERVICES_DIR ENVIRONMENTS_DIR ENVIRONMENT SERVICE_MAPPING_FILE
"

C_GREEN="" C_RED="" C_RESET=""
if [[ -t 1 ]]; then
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_RESET=$'\033[0m'
fi

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

csv_row() {
  [[ -n "${CSV_FILE}" ]] || return 0
  local out="" f sep=""
  for f in "$@"; do
    case "${f}" in
      *,* | *'"'*) f="\"${f//\"/\"\"}\"" ;;
    esac
    out="${out}${sep}${f}"; sep=","
  done
  printf '%s\n' "${out}" >> "${CSV_FILE}"
}

report() {
  local status="${1}" service="${2}" app="${3}" key="${4}" target="${5}" source="${6}"
  local colour=""
  case "${status}" in
    MATCH|CONFIG_MATCH)       colour="${C_GREEN}"; count_matches=$((count_matches + 1)) ;;
    MISMATCH|CONFIG_MISMATCH) colour="${C_RED}";   count_mismatches=$((count_mismatches + 1)) ;;
    *)                        count_errors=$((count_errors + 1)) ;;
  esac
  count_checked=$((count_checked + 1))
  log "${colour}${status}: ${service}/${app} '${key}' target=${target} source=${source}${colour:+${C_RESET}}"
  csv_row "${status}" "${service}" "${app}" "${key}" "${target}" "${source}"
}

banner() {
  cat <<'EOF'
   _   _  _ ___  _   _
  /_\ | \| |   \ \ / /   Automated Notifier of Drift in keYs
 / _ \| .` | |) \ V /
/_/ \_\_|\_|___/ |_|

EOF
}


# The only place a secret value is read. Values stay in memory: never logged, never written to the CSV.
read_secret() {
  local vault="${1}" name="${2}" azcli_dir="${3}"
  AZURE_CONFIG_DIR="${azcli_dir}" az keyvault secret show \
    --vault-name "${vault}" \
    --name "${name}" \
    --query value --output tsv 2>/dev/null
}

app_setting() {
  printf '%s' "${APP_SETTINGS_JSON}" | jq -r --arg k "${1}" '.[] | select(.name==$k) | .value'
}

has_app_setting() {
  printf '%s' "${APP_SETTINGS_JSON}" | jq -e --arg k "${1}" 'any(.[]; .name==$k)' >/dev/null
}

resource_group_for() {
  printf '%s\n' "${APP_SITES_TSV}" | awk -F'\t' -v n="${1}" '$1 == n { print $2; exit }'
}

resolve_app_services() {
  local wanted="${1}" service app_service
  while IFS='|' read -r service app_service; do
    case "${service}" in ''|\#*) continue ;; esac
    if [[ "${service}" == "${wanted}" ]]; then
      printf '%s\n' "${app_service}"
    fi
  done < "${SERVICE_MAPPING_FILE}"
}

parse_ref_field() {
  local reference="${1}" field="${2}"
  if [[ "${reference}" =~ ${field}=([^;\)]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Some secrets have no App Service setting because their value sits directly in
# the target (SEC) vault, keyed "<app-service-base><Suffix>". That applies when
# the remoteKey starts with the service stem on a camelCase boundary; prints the
# derived key, or nothing when the rule does not apply.
derive_sec_key() {
  local service="${1}" app_service="${2}" remote_key="${3}"
  local stem="${service%-service}"; stem="${stem%-job}"; stem="${stem%-frontend}"
  local remote_lc stem_lc base
  remote_lc="$(printf '%s' "${remote_key}" | tr '[:upper:]' '[:lower:]')"
  stem_lc="$(printf '%s' "${stem}" | tr '[:upper:]' '[:lower:]')"
  [[ "${remote_lc}" == "${stem_lc}"* && "${remote_key:${#stem}:1}" == [A-Z] ]] || return 0
  base="${app_service%-${ENVIRONMENT}}"; base="${base%-green}"; base="${base%-blue}"
  printf '%s' "${base}${remote_key:${#stem}}"
}

# Work out what the App Service actually uses for this secret. Sets the caller's
# "target" (a printable label) and "target_value"; reports and returns 1 when the
# secret cannot be resolved.
resolve_target() {
  local service="${1}" app="${2}" key="${3}" remote_key="${4}" setting="${5}" source="${6}"
  local vault name

  if [[ "${setting}" == *"@Microsoft.KeyVault("* ]]; then
    vault="$(parse_ref_field "${setting}" VaultName)"
    name="$(parse_ref_field "${setting}" SecretName)"
    if [[ -z "${vault}" || -z "${name}" ]]; then
      report ERROR_UNPARSEABLE_REF "${service}" "${app}" "${key}" "" ""
      return 1
    fi
    if [[ "${vault}" != "${TARGET_VAULT_NAME}" ]]; then
      log "WARN: ${service}/${app} '${key}' references vault '${vault}', expected '${TARGET_VAULT_NAME}'"
    fi
  elif [[ -n "${setting}" && "${setting}" != "null" ]]; then
    target="<literal>"
    target_value="${setting}"
    return 0
  else
    vault="${TARGET_VAULT_NAME}"
    name="$(derive_sec_key "${service}" "${app}" "${remote_key}")"
    if [[ -z "${name}" ]]; then
      report ERROR_ENV_VAR_MISSING "${service}" "${app}" "${key}" "" ""
      return 1
    fi
  fi

  target="${vault}/${name}"
  if ! target_value="$(read_secret "${vault}" "${name}" "${TARGET_VAULT_AZCLI_DIR}")"; then
    report ERROR_READ_TARGET "${service}" "${app}" "${key}" "${target}" "${source}"
    return 1
  fi
}

check_secret() {
  local service="${1}" app="${2}" key="${3}" remote_key="${4}"
  local source="${SOURCE_VAULT_NAME}/${remote_key}"
  local setting target target_value source_value status

  setting="$(app_setting "${key}")"
  resolve_target "${service}" "${app}" "${key}" "${remote_key}" "${setting}" "${source}" || return 0

  if ! source_value="$(read_secret "${SOURCE_VAULT_NAME}" "${remote_key}" "${SOURCE_VAULT_AZCLI_DIR}")"; then
    report ERROR_READ_SOURCE "${service}" "${app}" "${key}" "${target}" "${source}"
    return 0
  fi

  if [[ "${target_value}" == "${source_value}" ]]; then status=MATCH; else status=MISMATCH; fi
  report "${status}" "${service}" "${app}" "${key}" "${target}" "${source}"
}

check_config() {
  local service="${1}" app="${2}" key="${3}" env_yaml="${4}"
  local expected actual status

  expected="$(yq e ".config.\"${key}\" | tostring" "${env_yaml}")"
  if ! has_app_setting "${key}"; then
    report CONFIG_ENV_VAR_MISSING "${service}" "${app}" "${key}" "" "${expected}"
    return 0
  fi

  actual="$(app_setting "${key}")"
  if [[ "${actual}" == "${expected}" ]]; then status=CONFIG_MATCH; else status=CONFIG_MISMATCH; fi
  report "${status}" "${service}" "${app}" "${key}" "${actual}" "${expected}"
}

secret_pairs() {
  [[ -n "${1}" ]] || return 0
  yq e '.externalSecret.secrets // [] | .[] | .secretKey + "|" + .remoteKey' "${1}"
}

config_keys() {
  yq e '.config // {} | keys | .[]' "${1}"
}

check_app_service() {
  local service="${1}" app="${2}" secrets_yaml="${3}" env_yaml="${4}"
  local resource_group key remote_key

  resource_group="$(resource_group_for "${app}")"
  if [[ -z "${resource_group}" ]]; then
    report ERROR_APP_SERVICE_NOT_FOUND "${service}" "${app}" "" "" ""
    return 0
  fi

  APP_SETTINGS_JSON="$(AZURE_CONFIG_DIR="${TARGET_VAULT_AZCLI_DIR}" az webapp config appsettings list \
    --name "${app}" \
    --resource-group "${resource_group}" \
    --subscription "${APP_SERVICE_SUBSCRIPTION}" \
    --output json)"

  while IFS='|' read -r key remote_key; do
    [[ -n "${key}" && -n "${remote_key}" ]] || continue
    check_secret "${service}" "${app}" "${key}" "${remote_key}"
  done < <(secret_pairs "${secrets_yaml}")

  while IFS= read -r key; do
    [[ -n "${key}" ]] || continue
    check_config "${service}" "${app}" "${key}" "${env_yaml}"
  done < <(config_keys "${env_yaml}")
}

check_service() {
  local env_yaml="${1}"
  local service base_yaml secrets_yaml app_services app

  service="$(basename "${env_yaml}" .yaml)"
  base_yaml="${SERVICES_DIR}/${service}/base.yaml"

  # An environment file that declares its own secrets replaces the base list.
  secrets_yaml=""
  if [[ "$(yq e '.externalSecret // {} | has("secrets")' "${env_yaml}")" == "true" ]]; then
    secrets_yaml="${env_yaml}"
  elif [[ -f "${base_yaml}" ]]; then
    secrets_yaml="${base_yaml}"
  fi

  if [[ -z "$(secret_pairs "${secrets_yaml}")" && -z "$(config_keys "${env_yaml}")" ]]; then
    log "SKIP: ${service} has no secrets or config to check"
    count_skipped=$((count_skipped + 1))
    return 0
  fi

  app_services="$(resolve_app_services "${service}")"
  if [[ -z "${app_services}" ]]; then
    if [[ "${HIDE_UNRESOLVED}" -eq 0 ]]; then
      log "UNRESOLVED: ${service} has no entry in ${SERVICE_MAPPING_FILE}"
    fi
    count_unresolved=$((count_unresolved + 1))
    return 0
  fi

  for app in ${app_services}; do
    check_app_service "${service}" "${app}" "${secrets_yaml}" "${env_yaml}"
  done
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --hide-unresolved) HIDE_UNRESOLVED=1; shift ;;
      --csv) [[ $# -ge 2 ]] || fail "--csv requires a file path"; CSV_FILE="${2}"; shift 2 ;;
      --) shift; break ;;
      -*) fail "Unknown option '${1}' (usage: validator.sh [--hide-unresolved] [--csv <file>] [config-file])" ;;
      *) CONFIG_FILE="${1}"; shift ;;
    esac
  done
}

load_configuration() {
  local dep var

  for dep in az jq yq; do
    command -v "${dep}" >/dev/null 2>&1 || fail "${dep} is required but was not found on PATH"
  done

  if [[ -n "${CONFIG_FILE}" ]]; then
    [[ -f "${CONFIG_FILE}" ]] || fail "Config file '${CONFIG_FILE}' not found"
    set -a
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
    set +a
  fi

  for var in ${REQUIRED_VARS}; do
    [[ -n "${!var:-}" ]] || fail "${var} is required (set it in the config file or the environment)"
  done

  ENVIRONMENT_DIR="${ENVIRONMENTS_DIR}/${ENVIRONMENT}"
  [[ -d "${SERVICES_DIR}" ]] || fail "SERVICES_DIR '${SERVICES_DIR}' is not a directory"
  [[ -d "${ENVIRONMENT_DIR}" ]] || fail "ENVIRONMENT_DIR '${ENVIRONMENT_DIR}' is not a directory"
  [[ -f "${SERVICE_MAPPING_FILE}" ]] || fail "SERVICE_MAPPING_FILE '${SERVICE_MAPPING_FILE}' not found"

  if [[ -n "${CSV_FILE}" ]]; then
    : 2>/dev/null > "${CSV_FILE}" || fail "Cannot write CSV file '${CSV_FILE}'"
    csv_row status service app_service secret_key target source
  fi
}

main() {
  local env_yaml

  parse_arguments "$@"
  load_configuration
  banner

  APP_SITES_TSV="$(AZURE_CONFIG_DIR="${TARGET_VAULT_AZCLI_DIR}" az resource list \
    --subscription "${APP_SERVICE_SUBSCRIPTION}" \
    --resource-type "Microsoft.Web/sites" \
    --query "[].{name:name,rg:resourceGroup}" \
    --output tsv)"

  for env_yaml in "${ENVIRONMENT_DIR}"/*.yaml; do
    if [[ -f "${env_yaml}" ]]; then
      check_service "${env_yaml}"
    fi
  done

  log "Summary: checked=${count_checked} matches=${count_matches} mismatches=${count_mismatches} skipped=${count_skipped} unresolved=${count_unresolved} errors=${count_errors}"
  if [[ "${count_mismatches}" -gt 0 || "${count_errors}" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

# Sourced by validator.test.sh: define the functions, run nothing.
[[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]] || return 0

main "$@"
