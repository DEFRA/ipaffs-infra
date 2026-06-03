#!/bin/bash

## delete-namespace-identities.sh
##
## Deletes user-assigned managed identities created for one namespace by deploy-identities-from-services.sh.
## Defaults to dry-run. Set CONFIRM_DELETE=true to delete.

set -euo pipefail

: "${NAMESPACE:?NAMESPACE is required}"
: "${RESOURCE_GROUP_NAME:?RESOURCE_GROUP_NAME is required}"
: "${SUBSCRIPTION_NAME:?SUBSCRIPTION_NAME is required}"

CONFIRM_DELETE="${CONFIRM_DELETE:-false}"

lower_resource_group_name="$(echo "${RESOURCE_GROUP_NAME}" | tr '[:upper:]' '[:lower:]')"
identity_prefix="${lower_resource_group_name}-${NAMESPACE}-"

echo "Looking for managed identities in ${RESOURCE_GROUP_NAME} with prefix '${identity_prefix}'"

identity_names="$(az identity list \
  --subscription "${SUBSCRIPTION_NAME}" \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --query "[?starts_with(name, '${identity_prefix}')].name" \
  -o tsv)"

if [[ -z "${identity_names}" ]]; then
  echo "No managed identities found for namespace '${NAMESPACE}'"
  exit 0
fi

echo "Managed identities matched:"
echo "${identity_names}"

if [[ "${CONFIRM_DELETE}" != "true" ]]; then
  echo "Dry-run only. Set CONFIRM_DELETE=true to delete these identities."
  exit 0
fi

while IFS= read -r identity_name; do
  [[ -z "${identity_name}" ]] && continue
  echo "Deleting managed identity ${identity_name}"
  az identity delete \
    --subscription "${SUBSCRIPTION_NAME}" \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --name "${identity_name}"
done <<<"${identity_names}"

echo "Deleted namespace managed identities for '${NAMESPACE}'"

# vim: set ts=2 sts=2 sw=2 et:
