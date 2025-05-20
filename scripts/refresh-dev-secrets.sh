#!/usr/bin/env bash

REPO_DIR="$(cd "$(dirname $0)"/.. && pwd)"
SECRETS_CONFIG="${REPO_DIR}/scripts/secrets.yaml"
SECRETS_FILE="${REPO_DIR}/helm-charts/ipaffs/dev-secrets.yaml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check prerequisites
if ! command -v az >/dev/null 2>&1; then
  echo "\`az\` not available in PATH. Please install Azure CLI" >&2
  exit 1
fi

if [[ -z "${IPAFFS_KEYVAULT}" ]]; then
  echo "IPAFFS_KEYVAULT environment variable not set." >&2
  echo >&2
  echo "Please set this to name of the Key Vault from which to retrieve development secrets." >&2
  echo "e.g. \`export IPAFFS_KEYVAULT=fortknox\`" >&2
  exit 1
fi

set -e

retrieve_secret() {
  key_name="${1}"
  read -r -d '' value <<<"$(az keyvault secret show --vault-name "${IPAFFS_KEYVAULT}" -n "${key_name}" --query value -o tsv)"
  echo -n "${value}"
}

echo -e "${BLUE}:: Refreshing developer secrets from Key Vault${NC}"
echo -n >"${SECRETS_FILE}"

# Iterate over service types (corresponds to first-child charts, hardcoded for now)
for service_type in "backend" "frontend"; do
  echo "${service_type}:" >>"${SECRETS_FILE}"

  # Iterate over services in config file
  yq eval ".${service_type} | keys | .[]" "${SECRETS_CONFIG}" | while IFS= read -r service_name; do
    echo -e "${BLUE}:: Retrieving secrets for ${service_name}..${NC}"
    echo "  ${service_name}:" >>"${SECRETS_FILE}"
    echo "    secrets:" >>"${SECRETS_FILE}"

    # Iterate over secret names for each service
    yq eval ".${service_type}.${service_name}[]" "${SECRETS_CONFIG}" | while IFS= read -r secret_name; do
      value="$(retrieve_secret "${secret_name}")"

      # Replace double quote (") with backslash double quote (\") in the secret value, to avoid badyaml
      escaped_value="${value//\"/\\\"}"

      # Replace hyphen (-) with underscore (_) in secret name
      echo "      ${secret_name//-/_}: \"${escaped_value}\"" >>"${SECRETS_FILE}"
    done
    echo >>"${SECRETS_FILE}"
  done
  echo >>"${SECRETS_FILE}"
done