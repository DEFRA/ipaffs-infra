#!/bin/bash

set -euo pipefail

: "${AKS_NAME:?AKS_NAME is required}"
: "${AKS_RESOURCE_GROUP_NAME:?AKS_RESOURCE_GROUP_NAME is required}"
: "${AKS_SUBSCRIPTION_NAME:?AKS_SUBSCRIPTION_NAME is required}"
: "${LOCATION:?LOCATION is required}"
: "${MANAGED_IDENTITY_NAME:?MANAGED_IDENTITY_NAME is required}"
: "${NAMESPACE:?NAMESPACE is required}"
: "${OWNER_RESOURCE_GROUP_NAME:?OWNER_RESOURCE_GROUP_NAME is required}"

az aks install-cli
az aks get-credentials \
  --name "${AKS_NAME}" \
  --resource-group "${AKS_RESOURCE_GROUP_NAME}" \
  --subscription "${AKS_SUBSCRIPTION_NAME}" \
  --overwrite-existing

cat <<EOF | kubectl apply --namespace "${NAMESPACE}" --filename -
apiVersion: managedidentity.azure.com/v1api20230131
kind: UserAssignedIdentity
metadata:
  name: ${MANAGED_IDENTITY_NAME}
  annotations:
    serviceoperator.azure.com/reconcile-policy: manage
spec:
  location: ${LOCATION}
  owner:
    name: ${OWNER_RESOURCE_GROUP_NAME}
EOF

echo "Waiting for ASO clientId on ${MANAGED_IDENTITY_NAME} in namespace ${NAMESPACE}"
for _ in {1..60}; do
  client_id="$(kubectl get userassignedidentity.managedidentity.azure.com "${MANAGED_IDENTITY_NAME}" --namespace "${NAMESPACE}" --output jsonpath='{.status.clientId}' 2>/dev/null || true)"
  if [[ -n "${client_id}" ]]; then
    echo "ASO clientId resolved for ${MANAGED_IDENTITY_NAME}"
    exit 0
  fi
  sleep 5
done

echo "Timed out waiting for ASO clientId on ${MANAGED_IDENTITY_NAME}" >&2
kubectl get userassignedidentity.managedidentity.azure.com "${MANAGED_IDENTITY_NAME}" --namespace "${NAMESPACE}" --output yaml || true
exit 1

# vim: set ts=2 sts=2 sw=2 et:
