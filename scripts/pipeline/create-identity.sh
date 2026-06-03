#!/bin/bash

set -eu

IDENTITY_JSON="$(az identity create --subscription "${SUBSCRIPTION_NAME}" --name "${MANAGED_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP_NAME}" -o json)"
CLIENT_ID="$(jq -r '.clientId // .properties.clientId' <<<"${IDENTITY_JSON}")"
PRINCIPAL_ID="$(jq -r '.principalId // .properties.principalId' <<<"${IDENTITY_JSON}")"

if [[ -z "${CLIENT_ID}" || "${CLIENT_ID}" == "null" || -z "${PRINCIPAL_ID}" || "${PRINCIPAL_ID}" == "null" ]]; then
  echo "Unable to resolve clientId/principalId from managed identity create response for ${MANAGED_IDENTITY_NAME}" >&2
  exit 1
fi

az identity federated-credential create --subscription "${SUBSCRIPTION_NAME}" --identity-name "${MANAGED_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP_NAME}" --name "${AKS_CREDENTIAL}" --issuer "${AKS_ISSUER}" --audiences "${AKS_AUDIENCES}" --subject "${AKS_SUBJECT}"

if [[ -n "${CREATE_IDENTITY_OUTPUT_FILE:-}" ]]; then
  {
    echo "CLIENT_ID=${CLIENT_ID}"
    echo "PRINCIPAL_ID=${PRINCIPAL_ID}"
  } > "${CREATE_IDENTITY_OUTPUT_FILE}"
fi

set +x
echo "##vso[task.setvariable variable=principalId]${PRINCIPAL_ID}"
echo "##vso[task.setvariable variable=clientId;isOutput=true]${CLIENT_ID}"
echo "##vso[task.setvariable variable=principalName;isOutput=true]${MANAGED_IDENTITY_NAME}"

# vim: set ts=2 sts=2 sw=2 et:
