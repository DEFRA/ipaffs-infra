#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: disable.sh <action>

Actions:
  disable   Stop every listed App Service and Function App that is running.
  recover   Start every listed App Service and Function App that is stopped.

Only the apps in the environment list are touched. Every listed app must
exist before anything changes.

Environment:
  ENVIRONMENT         snd, tst, pre or prd.
  SUBSCRIPTION_NAME   Subscription that holds the listed apps.
  APPS_FILE           List of apps, one resourceGroup/appName per line;
                      defaults to lists/<env>-decommission-apps.txt
                      next to this script.
USAGE
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PARALLEL_JOBS="${PARALLEL_JOBS:-8}"
THROTTLE_ATTEMPTS="${THROTTLE_ATTEMPTS:-5}"
THROTTLE_DELAY_SECONDS="${THROTTLE_DELAY_SECONDS:-15}"
VERIFY_ATTEMPTS="${VERIFY_ATTEMPTS:-6}"
VERIFY_DELAY_SECONDS="${VERIFY_DELAY_SECONDS:-10}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

lowercase() {
  tr '[:upper:]' '[:lower:]' <<<"${1}"
}

normalise_environment() {
  case "$(lowercase "${1:-}")" in
    snd|tst|pre|prd)
      lowercase "${1}"
      ;;
    *)
      fail "ENVIRONMENT must be one of snd, tst, pre or prd; got '${1:-unset}'"
      ;;
  esac
}

# Retries while Azure throttles the request
run_cmd() {
  local attempt=1 output

  while true; do
    if output="$("$@" 2>&1)"; then
      [[ -z "${output}" ]] || echo "${output}"
      return 0
    fi

    if [[ "${attempt}" -lt "${THROTTLE_ATTEMPTS}" ]] && grep -qE '"Code":"429"|TooManyRequests|[Tt]hrottl' <<<"${output}"; then
      log "Azure is throttling, retrying in ${THROTTLE_DELAY_SECONDS}s"
      sleep "${THROTTLE_DELAY_SECONDS}"
      attempt=$((attempt + 1))
      continue
    fi

    echo "${output}" >&2
    return 1
  done
}

# Prints the listed apps without comments or blank lines
read_apps() {
  local line duplicates

  [[ -f "${APPS_FILE}" ]] || fail "App list '${APPS_FILE}' does not exist"

  sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "${APPS_FILE}" | grep -v '^$' > "${work_dir}/apps" || true
  if [[ ! -s "${work_dir}/apps" ]]; then
    grep -Fxq '# No apps to stop or recover' "${APPS_FILE}" || fail "No apps listed in '${APPS_FILE}'"
    return
  fi

  while IFS= read -r line; do
    [[ "${line}" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || fail "Line '${line}' in '${APPS_FILE}' is not resourceGroup/appName"
  done < "${work_dir}/apps"

  duplicates="$(tr '[:upper:]' '[:lower:]' < "${work_dir}/apps" | sort | uniq -d)"
  [[ -z "${duplicates}" ]] || fail "Apps listed more than once in '${APPS_FILE}': ${duplicates//$'\n'/, }"
}

# Prints key, id, state and display name for every site in the subscription
site_states() {
  {
    az webapp list --subscription "${SUBSCRIPTION_NAME}" --output json
    az functionapp list --subscription "${SUBSCRIPTION_NAME}" --output json
  } | jq -rs 'add | unique_by(.id)[] | [((.resourceGroup + "/" + .name) | ascii_downcase), .id, .state, (.resourceGroup + "/" + .name)] | @tsv'
}

# Joins the listed apps with their current state and marks missing ones
match_apps() {
  site_states > "${work_dir}/sites"
  awk -F'\t' 'NR == FNR { site[$1] = $0; next } { key = tolower($0); if (key in site) print site[key]; else print key "\tMISSING\tMISSING\t" $0 }' \
    "${work_dir}/sites" "${work_dir}/apps"
}

change_app() {
  local verb="${1}" resource_id="${2}" name="${3}"

  if ! run_cmd az webapp "${verb}" --ids "${resource_id}" --output none; then
    log "ERROR: could not ${verb} '${name}'"
    echo "${name}" >> "${work_dir}/failed"
  fi
}

apply_action() {
  local key resource_id state name jobs=0

  : > "${work_dir}/failed"
  CHANGED=0
  UNCHANGED=0

  while IFS=$'\t' read -r key resource_id state name; do
    if [[ "${state}" == "${TARGET_STATE}" ]]; then
      log "App '${name}' is already ${TARGET_STATE_TEXT}"
      UNCHANGED=$((UNCHANGED + 1))
      continue
    fi

    log "${ACTION_TEXT} '${name}' (${state})"
    CHANGED=$((CHANGED + 1))
    change_app "${VERB}" "${resource_id}" "${name}" &
    jobs=$((jobs + 1))

    # Bash 3.2 has no wait for a single job so run in batches
    if [[ "${jobs}" -ge "${PARALLEL_JOBS}" ]]; then
      wait
      jobs=0
    fi
  done < "${work_dir}/matched"
  wait
}

# Polls until every listed app reaches the target state
verify_apps() {
  local attempt=1 pending

  while true; do
    pending="$(match_apps | awk -F'\t' -v target="${TARGET_STATE}" '$3 != target { print $4 " (" $3 ")" }')"
    [[ -n "${pending}" ]] || return 0

    if [[ "${attempt}" -ge "${VERIFY_ATTEMPTS}" ]]; then
      log "ERROR: these apps are not ${TARGET_STATE_TEXT}"
      sed 's/^/  /' <<<"${pending}"
      return 1
    fi

    log "Waiting for $(wc -l <<<"${pending}" | tr -d ' ') app(s) to be ${TARGET_STATE_TEXT}"
    sleep "${VERIFY_DELAY_SECONDS}"
    attempt=$((attempt + 1))
  done
}

ACTION="${1:-}"
case "${ACTION}" in
  -h|--help)
    usage
    exit 0
    ;;
  disable)
    VERB="stop"
    ACTION_TEXT="Stopping"
    TARGET_STATE="Stopped"
    ;;
  recover)
    VERB="start"
    ACTION_TEXT="Starting"
    TARGET_STATE="Running"
    ;;
  *)
    usage
    fail "Action must be disable or recover"
    ;;
esac
TARGET_STATE_TEXT="$(lowercase "${TARGET_STATE}")"

ENVIRONMENT_NAME="$(normalise_environment "${ENVIRONMENT:-}")"
APPS_FILE="${APPS_FILE:-${script_dir}/lists/${ENVIRONMENT_NAME}-decommission-apps.txt}"
[[ -n "${SUBSCRIPTION_NAME:-}" ]] || fail "SUBSCRIPTION_NAME is required"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

log "Action=${ACTION} Environment=${ENVIRONMENT_NAME} Subscription=${SUBSCRIPTION_NAME}"
log "Reading apps from '${APPS_FILE}'"
read_apps
if [[ ! -s "${work_dir}/apps" ]]; then
  log "No apps to stop or recover in ${ENVIRONMENT_NAME}"
  exit 0
fi
log "Found $(wc -l < "${work_dir}/apps" | tr -d ' ') listed app(s)"

# Nothing changes unless every listed app exists
match_apps > "${work_dir}/matched"
missing="$(awk -F'\t' '$2 == "MISSING" { print "  " $4 }' "${work_dir}/matched")"
if [[ -n "${missing}" ]]; then
  log "ERROR: these listed apps do not exist in '${SUBSCRIPTION_NAME}'"
  echo "${missing}"
  fail "Nothing was changed"
fi

apply_action
failed_count="$(wc -l < "${work_dir}/failed" | tr -d ' ')"

if [[ "${failed_count}" -eq 0 ]] && ! verify_apps; then
  failed_count=1
fi

log "Summary: ${CHANGED} changed, ${UNCHANGED} already ${TARGET_STATE_TEXT}, ${failed_count} failed"
[[ "${failed_count}" -eq 0 ]] || fail "${ACTION} did not finish for every listed app"
log "Done"
