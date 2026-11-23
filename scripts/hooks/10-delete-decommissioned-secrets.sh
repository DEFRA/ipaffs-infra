#!/usr/bin/env bash
# Deletes the Key Vault secrets listed in decommissioned-secrets.txt from the environment's vault.
# Secrets are soft deleted and never purged, so they can be recovered within the vault retention period.
set -euo pipefail

fail() {
  echo "##vso[task.logissue type=error]$*"
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
list_file="${DECOMMISSIONED_SECRETS_FILE:-${hook_dir}/decommissioned-secrets.txt}"

[[ -n "${ENVIRONMENT:-}" ]] || fail "ENVIRONMENT is not set"
[[ -f "${list_file}" ]] || fail "Secret list '${list_file}' does not exist"

vault="$(tr '[:lower:]' '[:upper:]' <<<"${ENVIRONMENT}")IMPINFKV1401"
# az uses its default subscription when the stage does not pass one
subscription_args=(--subscription "${SUBSCRIPTION_ID:-}")
if [[ -z "${SUBSCRIPTION_ID:-}" ]]; then
  subscription_args=(--only-show-errors)
fi

# names only, ignoring comments, blank lines and surrounding spaces
names=()
while IFS= read -r name; do
  names+=("${name}")
done < <(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "${list_file}" | grep -v '^$' || true)

if [[ ${#names[@]} -eq 0 ]]; then
  log "No secrets listed in ${list_file}, nothing to do"
  exit 0
fi

az keyvault show --name "${vault}" "${subscription_args[@]}" --query name -o tsv > /dev/null \
  || fail "Key Vault ${vault} was not found or cannot be read"

# metadata only, secret values are never read
existing="$(az keyvault secret list --vault-name "${vault}" "${subscription_args[@]}" --query "[].name" -o tsv)" \
  || fail "Could not list the secrets in ${vault}"

log "Checking ${#names[@]} decommissioned secret(s) in ${vault} (DryRun=${DRY_RUN:-true})"

for name in "${names[@]}"; do
  if ! grep -qxF -- "${name}" <<<"${existing}"; then
    log "${name} is already absent from ${vault}"
    continue
  fi

  if [[ "${DRY_RUN:-true}" != "false" ]]; then
    log "Would delete ${name} from ${vault}"
    continue
  fi

  az keyvault secret delete --vault-name "${vault}" "${subscription_args[@]}" --name "${name}" -o none \
    || fail "Could not delete ${name} from ${vault}"
  log "Deleted ${name} from ${vault}"
done
