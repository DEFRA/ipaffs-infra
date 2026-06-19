#!/bin/bash

set -euo pipefail

: "${GROUP_ID:?GROUP_ID is required}"
: "${PRINCIPAL_ID:?PRINCIPAL_ID is required}"

logInfo() {
  echo "[remove-principal-from-group] $*" >&2
}

max_attempts=10
attempt=0
last_error=""

while (( attempt < max_attempts )); do
  (( ++attempt ))

  set +e
  RESULT="$(az ad group member remove -g "${GROUP_ID}" --member-id "${PRINCIPAL_ID}" 2>&1)"
  STATUS=$?
  set -e

  if (( STATUS == 0 )); then
    logInfo "Successfully removed principal '${PRINCIPAL_ID}' from group '${GROUP_ID}' on attempt ${attempt}/${max_attempts}"
    exit 0
  fi

  last_error="${RESULT}"

  # Treat already-removed/not-a-member as success.
  if [[ "${RESULT}" =~ "does not exist" ]] || \
     [[ "${RESULT}" =~ "Resource .* does not exist" ]] || \
     [[ "${RESULT}" =~ "One or more removed object references do not exist" ]]; then
    logInfo "Principal '${PRINCIPAL_ID}' is not a member of group '${GROUP_ID}'"
    exit 0
  fi

  if [[ "${RESULT}" =~ "Insufficient privileges" ]]; then
    logInfo "Insufficient privileges when removing principal '${PRINCIPAL_ID}' from group '${GROUP_ID}' on attempt ${attempt}/${max_attempts}. Raw CLI output: ${RESULT}"
    sleep 10
    continue
  fi

  if [[ "${RESULT}" =~ "Invalid" ]]; then
    logInfo "Invalid request while removing principal '${PRINCIPAL_ID}' from group '${GROUP_ID}'. Raw CLI output: ${RESULT}"
    exit 1
  fi

  logInfo "Attempt ${attempt}/${max_attempts} failed for group '${GROUP_ID}' principal '${PRINCIPAL_ID}': ${RESULT}"
  sleep 10
done

logInfo "Unable to remove principal '${PRINCIPAL_ID}' from group '${GROUP_ID}' after ${max_attempts} attempts. Last error: ${last_error}"
exit 1

# vim: set ts=2 sts=2 sw=2 et:
