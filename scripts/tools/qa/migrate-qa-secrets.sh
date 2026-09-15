#!/bin/bash

## migrate-qa-secrets.sh
##
## Moves QA automation secrets (names starting with "qa", case-insensitive) from the DEV Key Vault
## to the TST QA Key Vault: each secret is copied to the target and then deleted from the source.
##
## Safe to re-run. A secret that already exists in the target is not overwritten: if its value
## matches the source, the source copy is deleted; if it differs, both are left untouched and the
## run fails so the difference can be resolved by hand.
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

set -euo pipefail

SOURCE_VAULT_NAME="${SOURCE_VAULT_NAME:-DEVIMPINFKV1401}"
SOURCE_SUBSCRIPTION="AZR-IMP-DEV1"
TARGET_VAULT_NAME="${TARGET_VAULT_NAME:-TSTIMPINFKV1402}"
TARGET_SUBSCRIPTION="AZR-IMP-TST1"

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

echo ":: Moving secrets starting with 'qa' from ${SOURCE_VAULT_NAME} to ${TARGET_VAULT_NAME}"

source_names="$(list_secret_names "${SOURCE_VAULT_NAME}" "${SOURCE_SUBSCRIPTION}")"
target_names="$(list_secret_names "${TARGET_VAULT_NAME}" "${TARGET_SUBSCRIPTION}")"

moved=0
failures=0
shopt -s nocasematch
# Read names on fd 3 so az commands in the loop cannot consume them from stdin.
while read -r name <&3; do
  [[ -n "${name}" && "${name}" == qa* ]] || continue

  source_file="${WORK_DIR}/source"
  if ! download_secret "${SOURCE_VAULT_NAME}" "${SOURCE_SUBSCRIPTION}" "${name}" "${source_file}"; then
    echo "FAILED ${name} (download from source)" >&2
    failures=$((failures + 1))
    continue
  fi

  if grep -qxF "${name}" <<<"${target_names}"; then
    target_file="${WORK_DIR}/target"
    if ! download_secret "${TARGET_VAULT_NAME}" "${TARGET_SUBSCRIPTION}" "${name}" "${target_file}"; then
      echo "FAILED ${name} (download from target)" >&2
      failures=$((failures + 1))
      continue
    fi
    if ! cmp -s "${source_file}" "${target_file}"; then
      echo "FAILED ${name} (already exists in target with a different value; left both untouched)" >&2
      failures=$((failures + 1))
      continue
    fi
  else
    if ! content_type="$(az keyvault secret show --vault-name "${SOURCE_VAULT_NAME}" --subscription "${SOURCE_SUBSCRIPTION}" \
        --name "${name}" --query contentType --output tsv)"; then
      echo "FAILED ${name} (read content type)" >&2
      failures=$((failures + 1))
      continue
    fi
    if ! az keyvault secret set --vault-name "${TARGET_VAULT_NAME}" --subscription "${TARGET_SUBSCRIPTION}" \
        --name "${name}" --file "${source_file}" --encoding utf-8 ${content_type:+--content-type "${content_type}"} >/dev/null; then
      echo "FAILED ${name} (copy to target)" >&2
      failures=$((failures + 1))
      continue
    fi
  fi

  if ! az keyvault secret delete --vault-name "${SOURCE_VAULT_NAME}" --subscription "${SOURCE_SUBSCRIPTION}" \
      --name "${name}" >/dev/null; then
    echo "FAILED ${name} (delete from source)" >&2
    failures=$((failures + 1))
    continue
  fi

  echo "MOVED ${name}"
  moved=$((moved + 1))
done 3<<<"${source_names}"

echo ":: moved=${moved} failed=${failures}"
[[ ${failures} -eq 0 ]]
