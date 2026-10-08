#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: run-hooks.sh

Runs every hook script in HOOKS_DIR in lexical filename order. Scripts in
HOOKS_DIR/<ENVIRONMENT>/ are merged in by filename: a same-named script
replaces the common one, a new name is added to the sequence.

Environment:
  ENVIRONMENT   dev, tst, pre or prd.
  HOOKS_DIR     Directory holding the hooks; defaults to scripts/hooks.
  DRY_RUN       true or false; defaults to true. Passed through to each hook.
USAGE
}

fail() {
  echo "##vso[task.logissue type=error]$*"
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

lowercase() {
  tr '[:upper:]' '[:lower:]' <<<"${1}"
}

normalise_bool() {
  case "$(lowercase "${1:-true}")" in
    1|true|yes|y|on)
      echo true
      ;;
    0|false|no|n|off)
      echo false
      ;;
    *)
      fail "DRY_RUN must be true or false; got '${1}'"
      ;;
  esac
}

normalise_environment() {
  case "$(lowercase "${1:-}")" in
    dev|tst|pre|prd)
      lowercase "${1}"
      ;;
    *)
      fail "ENVIRONMENT must be one of dev, tst, pre or prd; got '${1:-unset}'"
      ;;
  esac
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

ENVIRONMENT="$(normalise_environment "${ENVIRONMENT:-}")"
DRY_RUN="$(normalise_bool "${DRY_RUN:-true}")"
HOOKS_DIR="${HOOKS_DIR:-scripts/hooks}"
export ENVIRONMENT DRY_RUN

[[ -d "${HOOKS_DIR}" ]] || fail "Hooks directory '${HOOKS_DIR}' does not exist"

declare -A hooks=()
shopt -s nullglob
for hook in "${HOOKS_DIR}"/*.sh "${HOOKS_DIR}/${ENVIRONMENT}"/*.sh; do
  hooks["$(basename "${hook}")"]="${hook}"
done
shopt -u nullglob

if [[ ${#hooks[@]} -eq 0 ]]; then
  log "No hooks found in ${HOOKS_DIR}; nothing to run"
  exit 0
fi

mapfile -t ordered < <(printf '%s\n' "${!hooks[@]}" | sort)

log "Running ${#ordered[@]} hook(s) for ${ENVIRONMENT} (DryRun=${DRY_RUN})"

for name in "${ordered[@]}"; do
  path="${hooks[${name}]}"
  echo "##[section]Running hook ${name} (${path})"
  bash "${path}" && continue
  exit_code=$?
  echo "##vso[task.logissue type=error]Hook ${name} failed with exit code ${exit_code}"
  echo "ERROR: Hook ${name} (${path}) failed with exit code ${exit_code}" >&2
  exit "${exit_code}"
done

log "All hooks completed"
