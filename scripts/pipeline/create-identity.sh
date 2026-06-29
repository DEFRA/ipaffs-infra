#!/bin/bash

set -eu

IDENTITY_JSON="$(az identity create --subscription "${SUBSCRIPTION_NAME}" --name "${MANAGED_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP_NAME}" -o json)"
CLIENT_ID="$(jq -r '.clientId // .properties.clientId' <<<"${IDENTITY_JSON}")"
PRINCIPAL_ID="$(jq -r '.principalId // .properties.principalId' <<<"${IDENTITY_JSON}")"

if [[ -z "${CLIENT_ID}" || "${CLIENT_ID}" == "null" || -z "${PRINCIPAL_ID}" || "${PRINCIPAL_ID}" == "null" ]]; then
  echo "Unable to resolve clientId/principalId from managed identity create response for ${MANAGED_IDENTITY_NAME}" >&2
  exit 1
fi

max_attempts=10
attempt=0
wait=2
last_error=""
federated_credential_created=false

while (( attempt < max_attempts )); do
  (( ++attempt ))

  set +e
  FEDERATED_CREDENTIAL_OUTPUT="$(az identity federated-credential create --subscription "${SUBSCRIPTION_NAME}" --identity-name "${MANAGED_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP_NAME}" --name "${AKS_CREDENTIAL}" --issuer "${AKS_ISSUER}" --audiences "${AKS_AUDIENCES}" --subject "${AKS_SUBJECT}" -o none 2>&1)"
  status=$?
  set -e

  if [[ ${status} -eq 0 ]]; then
    federated_credential_created=true
    break
  fi

  last_error="${FEDERATED_CREDENTIAL_OUTPUT}"

  if [[ "${FEDERATED_CREDENTIAL_OUTPUT}" =~ NotFound || "${FEDERATED_CREDENTIAL_OUTPUT}" =~ ResourceNotFound || "${FEDERATED_CREDENTIAL_OUTPUT}" =~ "Insufficient privileges" ]]; then
    echo "Federated credential create for ${MANAGED_IDENTITY_NAME} failed on attempt ${attempt}/${max_attempts}; retrying in ${wait}s. Raw CLI output: ${FEDERATED_CREDENTIAL_OUTPUT}" >&2
    sleep "${wait}"
    (( wait*=2 ))
    (( wait > 30 )) && wait=30
    continue
  fi

  echo "${FEDERATED_CREDENTIAL_OUTPUT}" >&2
  exit "${status}"
done

if [[ "${federated_credential_created}" != "true" ]]; then
  echo "Unable to create federated credential for ${MANAGED_IDENTITY_NAME} after ${max_attempts} attempts. Last error: ${last_error}" >&2
  exit 1
fi

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

