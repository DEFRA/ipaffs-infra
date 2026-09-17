#!/bin/bash

## migrate-qa-secrets.sh
##
## Moves QA automation secrets (names starting with "qa", case-insensitive) from the DEV Key Vault
## to the TST QA Key Vault: each secret is copied to the target and, when DELETE_FROM_SOURCE=true,
## then deleted from the source.
##
## Safe to re-run. A secret that already exists in the target is not overwritten: if its value
## matches the source, it counts as copied (and the source copy is deleted when DELETE_FROM_SOURCE=true);
## if it differs, both are left untouched and the run fails so the difference can be resolved by hand.
##
## The vaults are in different subscriptions, so `az keyvault secret backup/restore` cannot be used.
## Values are downloaded into a private temp directory and uploaded from there, so they never
## appear in command arguments, shell variables, the terminal or a log.
##
## Both vaults have public network access disabled; run this from a network that can reach their
## private endpoints, signed in (`az login`) with read/delete on the source and write on the target.
##
## usage $0
## Environment variable overrides
## SOURCE_VAULT_NAME - Default: DEVIMPINFKV1401
## TARGET_VAULT_NAME - Default: TSTIMPINFKV1402
## DELETE_FROM_SOURCE - Default: false. Set to true to delete each secret from the source once it is in the target.

set -euo pipefail

SOURCE_VAULT_NAME="${SOURCE_VAULT_NAME:-DEVIMPINFKV1401}"
SOURCE_SUBSCRIPTION="AZR-IMP-DEV1"
TARGET_VAULT_NAME="${TARGET_VAULT_NAME:-TSTIMPINFKV1402}"
TARGET_SUBSCRIPTION="AZR-IMP-TST1"
DELETE_FROM_SOURCE="${DELETE_FROM_SOURCE:-false}"

if [[ "${DELETE_FROM_SOURCE}" != "true" && "${DELETE_FROM_SOURCE}" != "false" ]]; then
  echo "DELETE_FROM_SOURCE must be true or false" >&2
  exit 1
fi

if [[ "${SOURCE_VAULT_NAME}" == "${TARGET_VAULT_NAME}" ]]; then
  echo "Source and target vaults must differ" >&2
  exit 1
fi

umask 077
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

list_secret_names() {
  az keyvault secret list --vault-name "${1}" --subscription "${2}" --query "[?attributes.enabled].name" --output tsv
}

download_secret() {
  rm -f "${4}"
  az keyvault secret download --vault-name "${1}" --subscription "${2}" --name "${3}" --file "${4}" --encoding utf-8 >/dev/null
}

fail() {
  echo "FAILED ${1} (${2})" >&2
}

exists_in_target() {
  grep -qxF "${1}" <<<"${target_names}"
}

# Succeeds only if the secret already in the target has the same value as the source.
target_matches_source() {
  local name="${1}" source_file="${2}"
  local target_file="${WORK_DIR}/target"

  download_secret "${TARGET_VAULT_NAME}" "${TARGET_SUBSCRIPTION}" "${name}" "${target_file}" \
    || { fail "${name}" "download from target"; return 1; }

  cmp -s "${source_file}" "${target_file}" \
    || { fail "${name}" "already exists in target with a different value; left both untouched"; return 1; }
}

copy_to_target() {
  local name="${1}" source_file="${2}"
  local content_type

  content_type="$(az keyvault secret show --vault-name "${SOURCE_VAULT_NAME}" --subscription "${SOURCE_SUBSCRIPTION}" \
      --name "${name}" --query contentType --output tsv)" \
    || { fail "${name}" "read content type"; return 1; }

  az keyvault secret set --vault-name "${TARGET_VAULT_NAME}" --subscription "${TARGET_SUBSCRIPTION}" \
      --name "${name}" --file "${source_file}" --encoding utf-8 ${content_type:+--content-type "${content_type}"} >/dev/null \
    || { fail "${name}" "copy to target"; return 1; }
}

delete_from_source() {
  local name="${1}"

  az keyvault secret delete --vault-name "${SOURCE_VAULT_NAME}" --subscription "${SOURCE_SUBSCRIPTION}" \
      --name "${name}" >/dev/null \
    || { fail "${name}" "delete from source"; return 1; }
}

migrate_secret() {
  local name="${1}"
  local source_file="${WORK_DIR}/source"

  download_secret "${SOURCE_VAULT_NAME}" "${SOURCE_SUBSCRIPTION}" "${name}" "${source_file}" \
    || { fail "${name}" "download from source"; return 1; }

  if exists_in_target "${name}"; then
    target_matches_source "${name}" "${source_file}" || return 1
  else
    copy_to_target "${name}" "${source_file}" || return 1
  fi

  if [[ "${DELETE_FROM_SOURCE}" == "true" ]]; then
    delete_from_source "${name}" || return 1
  fi
}

if [[ "${DELETE_FROM_SOURCE}" == "true" ]]; then
  action="MOVED"
else
  action="COPIED"
fi

echo ":: Processing secrets starting with 'qa' from ${SOURCE_VAULT_NAME} to ${TARGET_VAULT_NAME} (DELETE_FROM_SOURCE=${DELETE_FROM_SOURCE})"

source_names="$(list_secret_names "${SOURCE_VAULT_NAME}" "${SOURCE_SUBSCRIPTION}")"
target_names="$(list_secret_names "${TARGET_VAULT_NAME}" "${TARGET_SUBSCRIPTION}")"

succeeded=0
failures=0
shopt -s nocasematch
# Read names on fd 3 so az commands in the loop cannot consume them from stdin.
while read -r name <&3; do
  [[ -n "${name}" && "${name}" == qa* ]] || continue

  if migrate_secret "${name}"; then
    echo "${action} ${name}"
    succeeded=$((succeeded + 1))
  else
    failures=$((failures + 1))
  fi
done 3<<<"${source_names}"

echo ":: $(tr '[:upper:]' '[:lower:]' <<<"${action}")=${succeeded} failed=${failures}"
[[ ${failures} -eq 0 ]]
