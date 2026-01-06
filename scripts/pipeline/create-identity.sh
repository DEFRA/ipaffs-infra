#!/bin/bash

set -eux

az identity create --name "${MANAGED_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP_NAME}"
CLIENT_ID="$(az identity show --name "${MANAGED_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP_NAME}" --query clientId --output tsv)"
PRINCIPAL_ID="$(az identity show --name "${MANAGED_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP_NAME}" --query principalId --output tsv)"

az identity federated-credential create --identity-name "${MANAGED_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP_NAME}" --name "${AKS_CREDENTIAL}" --issuer "${AKS_ISSUER}" --audiences "${AKS_AUDIENCES}" --subject "${AKS_SUBJECT}"

set +x
echo "##vso[task.setvariable variable=principalId]${PRINCIPAL_ID}"
echo "##vso[task.setvariable variable=clientId;isOutput=true]${CLIENT_ID}"
echo "##vso[task.setvariable variable=principalName;isOutput=true]${MANAGED_IDENTITY_NAME}"

# vim: set ts=2 sts=2 sw=2 et:
