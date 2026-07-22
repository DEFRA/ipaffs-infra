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

set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

record_error() {
  log "ERROR: $*"
  count_errors=$((count_errors + 1))
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

C_GREEN="" C_RED="" C_RESET=""
if [[ -t 1 ]]; then
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_RESET=$'\033[0m'
fi

read_secret() {
  local vault="${1}" name="${2}" azcli_dir="${3}"
  AZURE_CONFIG_DIR="${azcli_dir}" az keyvault secret show \
    --vault-name "${vault}" \
    --name "${name}" \
    --query value --output tsv 2>/dev/null
}

parse_ref_field() {
  local reference="${1}" field="${2}"
  if [[ "${reference}" =~ ${field}=([^;\)]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

banner() {
  cat <<'EOF'
   _   _  _ ___  _   _
  /_\ | \| |   \ \ / /   Automated Notifier of Drift in keYs
 / _ \| .` | |) \ V /
/_/ \_\_|\_|___/ |_|

EOF
}

# dependencies
for dep in az jq yq; do
  command -v "${dep}" >/dev/null 2>&1 || fail "${dep} is required but was not found on PATH"
done

# arguments
HIDE_UNRESOLVED=0
CSV_FILE=""
CONFIG_FILE=""
while [[ $# -gt 0 ]]; do
  case "${1}" in
    --hide-unresolved) HIDE_UNRESOLVED=1; shift ;;
    --csv) [[ $# -ge 2 ]] || fail "--csv requires a file path"; CSV_FILE="${2}"; shift 2 ;;
    --) shift; break ;;
    -*) fail "Unknown option '${1}' (usage: validator.sh [--hide-unresolved] [--csv <file>] [config-file])" ;;
    *) CONFIG_FILE="${1}"; shift ;;
  esac
done

# configuration: source the given config file, or use the current environment if none is passed.
if [[ -n "${CONFIG_FILE}" ]]; then
  [[ -f "${CONFIG_FILE}" ]] || fail "Config file '${CONFIG_FILE}' not found"
  set -a
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
  set +a
fi

: "${SOURCE_VAULT_NAME:?SOURCE_VAULT_NAME is required}"
: "${SOURCE_VAULT_AZCLI_DIR:?SOURCE_VAULT_AZCLI_DIR is required}"
: "${TARGET_VAULT_NAME:?TARGET_VAULT_NAME is required}"
: "${TARGET_VAULT_AZCLI_DIR:?TARGET_VAULT_AZCLI_DIR is required}"
: "${APP_SERVICE_SUBSCRIPTION:?APP_SERVICE_SUBSCRIPTION is required}"
: "${SERVICES_DIR:?SERVICES_DIR is required}"
: "${ENVIRONMENTS_DIR:?ENVIRONMENTS_DIR is required}"
: "${ENVIRONMENT:?ENVIRONMENT is required}"
: "${SERVICE_MAPPING_FILE:?SERVICE_MAPPING_FILE is required}"

ENVIRONMENT_DIR="${ENVIRONMENTS_DIR}/${ENVIRONMENT}"
[[ -d "${SERVICES_DIR}" ]] || fail "SERVICES_DIR '${SERVICES_DIR}' is not a directory"
[[ -d "${ENVIRONMENT_DIR}" ]] || fail "ENVIRONMENT_DIR '${ENVIRONMENT_DIR}' is not a directory"
[[ -f "${SERVICE_MAPPING_FILE}" ]] || fail "SERVICE_MAPPING_FILE '${SERVICE_MAPPING_FILE}' not found"

banner

if [[ -n "${CSV_FILE}" ]]; then
  : 2>/dev/null > "${CSV_FILE}" || fail "Cannot write CSV file '${CSV_FILE}'"
  csv_row status service app_service secret_key target source
fi

count_checked=0
count_matches=0
count_mismatches=0
count_skipped=0
count_unresolved=0
count_errors=0

resolve_app_services() {
  local service_name="${1}"
  local map_service app_service
  while IFS='|' read -r map_service app_service; do
    case "${map_service}" in ''|\#*) continue ;; esac
    if [[ "${map_service}" == "${service_name}" ]]; then
      printf '%s\n' "${app_service}"
    fi
  done < "${SERVICE_MAPPING_FILE}"
}

app_sites_tsv="$(AZURE_CONFIG_DIR="${TARGET_VAULT_AZCLI_DIR}" az resource list \
  --subscription "${APP_SERVICE_SUBSCRIPTION}" \
  --resource-type "Microsoft.Web/sites" \
  --query "[].{name:name,rg:resourceGroup}" \
  --output tsv)"

resource_group_for() {
  printf '%s\n' "${app_sites_tsv}" | awk -F'\t' -v n="${1}" '$1 == n { print $2; exit }'
}

for env_yaml in "${ENVIRONMENT_DIR}"/*.yaml; do
  [[ -f "${env_yaml}" ]] || continue

  service="$(basename "${env_yaml}" .yaml)"
  base_yaml="${SERVICES_DIR}/${service}/base.yaml"

  secrets_yaml=""
  if [[ "$(yq e '.externalSecret // {} | has("secrets")' "${env_yaml}")" == "true" ]]; then
    secrets_yaml="${env_yaml}"
  elif [[ -f "${base_yaml}" ]]; then
    secrets_yaml="${base_yaml}"
  fi
  secrets_present=0
  [[ -n "${secrets_yaml}" ]] && secrets_present="$(yq e '[.externalSecret.secrets // [] | .[]] | length' "${secrets_yaml}")"

  # Config: the environment file's .config map (plain, non-secret env vars).
  config_present="$(yq e '.config // {} | length' "${env_yaml}")"

  if [[ "${secrets_present}" == "0" && "${config_present}" == "0" ]]; then
    log "SKIP: ${service} has no secrets or config to check"
    count_skipped=$((count_skipped + 1))
    continue
  fi

  app_services="$(resolve_app_services "${service}")"
  if [[ -z "${app_services}" ]]; then
    [[ "${HIDE_UNRESOLVED}" -eq 1 ]] || log "UNRESOLVED: ${service} has no entry in ${SERVICE_MAPPING_FILE}"
    count_unresolved=$((count_unresolved + 1))
    continue
  fi

  for app_service in ${app_services}; do

    resource_group="$(resource_group_for "${app_service}")"
    if [[ -z "${resource_group}" ]]; then
      record_error "App Service '${app_service}' (service '${service}') not found in ${APP_SERVICE_SUBSCRIPTION}"
      csv_row ERROR_APP_SERVICE_NOT_FOUND "${service}" "${app_service}" "" "" ""
      continue
    fi

    app_settings_json="$(AZURE_CONFIG_DIR="${TARGET_VAULT_AZCLI_DIR}" az webapp config appsettings list \
      --name "${app_service}" \
      --resource-group "${resource_group}" \
      --subscription "${APP_SERVICE_SUBSCRIPTION}" \
      --output json)"

    [[ "${secrets_present}" != "0" ]] && while IFS='|' read -r secret_key remote_key; do
      [[ -n "${secret_key}" && -n "${remote_key}" ]] || continue

      reference="$(printf '%s' "${app_settings_json}" | jq -r --arg k "${secret_key}" \
        '.[] | select(.name==$k) | .value')"

      source="${SOURCE_VAULT_NAME}/${remote_key}"

      # An app setting is a @Microsoft.KeyVault(...) reference, a literal value, or absent.
      # When absent, some secrets still live directly in the target (SEC) vault under <app-service-base><suffix> when
      # the remoteKey is prefixed with the service name; validate those, otherwise it is genuinely missing.
      if [[ -z "${reference}" || "${reference}" == "null" ]]; then
        stem="${service%-service}"; stem="${stem%-job}"; stem="${stem%-frontend}"
        rk_lc="$(printf '%s' "${remote_key}" | tr '[:upper:]' '[:lower:]')"
        stem_lc="$(printf '%s' "${stem}" | tr '[:upper:]' '[:lower:]')"
        next="${remote_key:${#stem}:1}"
        if [[ "${rk_lc}" == "${stem_lc}"* && "${next}" == [A-Z] ]]; then
          base="${app_service%-${ENVIRONMENT}}"; base="${base%-green}"; base="${base%-blue}"
          derived="${base}${remote_key:${#stem}}"
          target="${TARGET_VAULT_NAME}/${derived}"
          count_checked=$((count_checked + 1))
          if ! target_value="$(read_secret "${TARGET_VAULT_NAME}" "${derived}" "${TARGET_VAULT_AZCLI_DIR}")"; then
            record_error "${service}/${app_service} could not read target secret '${derived}' from vault '${TARGET_VAULT_NAME}'"
            csv_row ERROR_READ_TARGET "${service}" "${app_service}" "${secret_key}" "${target}" "${source}"
            continue
          fi
        else
          record_error "${service}/${app_service} env var '${secret_key}' not set on App Service"
          csv_row ERROR_ENV_VAR_MISSING "${service}" "${app_service}" "${secret_key}" "" ""
          continue
        fi
      elif [[ "${reference}" == *"@Microsoft.KeyVault("* ]]; then
        parsed_vault="$(parse_ref_field "${reference}" VaultName)"
        parsed_secret="$(parse_ref_field "${reference}" SecretName)"
        if [[ -z "${parsed_vault}" || -z "${parsed_secret}" ]]; then
          record_error "${service}/${app_service} env var '${secret_key}' is not a parseable KeyVault reference"
          csv_row ERROR_UNPARSEABLE_REF "${service}" "${app_service}" "${secret_key}" "" ""
          continue
        fi
        if [[ "${parsed_vault}" != "${TARGET_VAULT_NAME}" ]]; then
          log "WARN: ${service}/${app_service} '${secret_key}' references vault '${parsed_vault}', expected '${TARGET_VAULT_NAME}'"
        fi
        target="${parsed_vault}/${parsed_secret}"
        count_checked=$((count_checked + 1))
        if ! target_value="$(read_secret "${parsed_vault}" "${parsed_secret}" "${TARGET_VAULT_AZCLI_DIR}")"; then
          record_error "${service}/${app_service} could not read target secret '${parsed_secret}' from vault '${parsed_vault}'"
          csv_row ERROR_READ_TARGET "${service}" "${app_service}" "${secret_key}" "${target}" "${source}"
          continue
        fi
      else
        # Literal secret value held inline on the App Service — compare as-is.
        target="<literal>"
        count_checked=$((count_checked + 1))
        target_value="${reference}"
      fi

      if ! source_value="$(read_secret "${SOURCE_VAULT_NAME}" "${remote_key}" "${SOURCE_VAULT_AZCLI_DIR}")"; then
        record_error "${service}/${app_service} could not read source secret '${remote_key}' from vault '${SOURCE_VAULT_NAME}'"
        csv_row ERROR_READ_SOURCE "${service}" "${app_service}" "${secret_key}" "${target}" "${source}"
        unset target_value
        continue
      fi

      if [[ "${target_value}" == "${source_value}" ]]; then
        log "${C_GREEN}MATCH: ${service}/${app_service} env '${secret_key}' -> ${target} == ${source}${C_RESET}"
        csv_row MATCH "${service}" "${app_service}" "${secret_key}" "${target}" "${source}"
        count_matches=$((count_matches + 1))
      else
        log "${C_RED}MISMATCH: ${service}/${app_service} env '${secret_key}' -> target ${target} != source ${source}${C_RESET}"
        csv_row MISMATCH "${service}" "${app_service}" "${secret_key}" "${target}" "${source}"
        count_mismatches=$((count_mismatches + 1))
      fi

      unset target_value source_value reference
    done < <(yq e '.externalSecret.secrets[] | .secretKey + "|" + .remoteKey' "${secrets_yaml}")

    [[ "${config_present}" != "0" ]] && while IFS= read -r cfg_key; do
      [[ -n "${cfg_key}" ]] || continue
      cfg_expected="$(yq e ".config.\"${cfg_key}\" | tostring" "${env_yaml}")"

      if ! printf '%s' "${app_settings_json}" | jq -e --arg k "${cfg_key}" 'any(.[]; .name==$k)' >/dev/null; then
        record_error "${service}/${app_service} config '${cfg_key}' not set on App Service"
        csv_row CONFIG_ENV_VAR_MISSING "${service}" "${app_service}" "${cfg_key}" "" "${cfg_expected}"
        continue
      fi
      cfg_actual="$(printf '%s' "${app_settings_json}" | jq -r --arg k "${cfg_key}" \
        '.[] | select(.name==$k) | .value')"
      count_checked=$((count_checked + 1))

      if [[ "${cfg_actual}" == "${cfg_expected}" ]]; then
        log "${C_GREEN}CONFIG_MATCH: ${service}/${app_service} config '${cfg_key}' == '${cfg_expected}'${C_RESET}"
        csv_row CONFIG_MATCH "${service}" "${app_service}" "${cfg_key}" "${cfg_actual}" "${cfg_expected}"
        count_matches=$((count_matches + 1))
      else
        log "${C_RED}CONFIG_MISMATCH: ${service}/${app_service} config '${cfg_key}' -> app='${cfg_actual}' expected='${cfg_expected}'${C_RESET}"
        csv_row CONFIG_MISMATCH "${service}" "${app_service}" "${cfg_key}" "${cfg_actual}" "${cfg_expected}"
        count_mismatches=$((count_mismatches + 1))
      fi
    done < <(yq e '.config // {} | keys | .[]' "${env_yaml}")

  done
done

log "Summary: checked=${count_checked} matches=${count_matches} mismatches=${count_mismatches} skipped=${count_skipped} unresolved=${count_unresolved} errors=${count_errors}"
if [[ "${count_mismatches}" -gt 0 || "${count_errors}" -gt 0 ]]; then
  exit 1
fi
exit 0
