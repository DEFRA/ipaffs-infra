#!/bin/bash

set -eu

identity_was_prefetched=false

if [[ -n "${PREFETCHED_IDENTITY_CLIENT_ID:-}" && -n "${PREFETCHED_IDENTITY_PRINCIPAL_ID:-}" ]]; then
  CLIENT_ID="${PREFETCHED_IDENTITY_CLIENT_ID}"
  PRINCIPAL_ID="${PREFETCHED_IDENTITY_PRINCIPAL_ID}"
  identity_was_prefetched=true
  echo "Managed identity ${MANAGED_IDENTITY_NAME} already exists; skipping create"
else
  if [[ -n "${PREFETCHED_IDENTITY_CLIENT_ID:-}" || -n "${PREFETCHED_IDENTITY_PRINCIPAL_ID:-}" ]]; then
    echo "Ignoring incomplete prefetched identity data for ${MANAGED_IDENTITY_NAME}; continuing with create/update" >&2
  fi

  identity_create_started_at="${SECONDS}"
  IDENTITY_JSON="$(az identity create --subscription "${SUBSCRIPTION_NAME}" --name "${MANAGED_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP_NAME}" -o json)"
  echo "Managed identity create/update for ${MANAGED_IDENTITY_NAME} completed in $((SECONDS - identity_create_started_at))s"
  CLIENT_ID="$(jq -r '.clientId // .properties.clientId' <<<"${IDENTITY_JSON}")"
  PRINCIPAL_ID="$(jq -r '.principalId // .properties.principalId' <<<"${IDENTITY_JSON}")"
fi

if [[ -z "${CLIENT_ID}" || "${CLIENT_ID}" == "null" || -z "${PRINCIPAL_ID}" || "${PRINCIPAL_ID}" == "null" ]]; then
  echo "Unable to resolve clientId/principalId from managed identity create response for ${MANAGED_IDENTITY_NAME}" >&2
  exit 1
fi

max_attempts=10
attempt=0
wait=2
last_error=""
federated_credential_created=false

if [[ "${identity_was_prefetched}" == "true" ]]; then
  credential_lookup_started_at="${SECONDS}"
  set +e
  EXISTING_FEDERATED_CREDENTIAL="$(az identity federated-credential show --subscription "${SUBSCRIPTION_NAME}" --identity-name "${MANAGED_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP_NAME}" --name "${AKS_CREDENTIAL}" -o json 2>&1)"
  credential_lookup_status=$?
  set -e

  if [[ ${credential_lookup_status} -eq 0 ]] && jq -e \
    --arg issuer "${AKS_ISSUER}" \
    --arg subject "${AKS_SUBJECT}" \
    --arg audience "${AKS_AUDIENCES}" \
    '((.issuer // .properties.issuer // "") == $issuer)
      and ((.subject // .properties.subject // "") == $subject)
      and ((.audiences // .properties.audiences // []) == [$audience])' \
    <<<"${EXISTING_FEDERATED_CREDENTIAL}" > /dev/null 2>&1; then
    federated_credential_created=true
    echo "Federated credential ${AKS_CREDENTIAL} already matches in $((SECONDS - credential_lookup_started_at))s; skipping create/update"
  elif [[ ${credential_lookup_status} -eq 0 ]]; then
    echo "Federated credential ${AKS_CREDENTIAL} is missing or differs from the requested configuration; continuing with create/update"
  else
    echo "Unable to confirm federated credential ${AKS_CREDENTIAL}; continuing with the existing create/update path" >&2
  fi
fi

while (( attempt < max_attempts )); do
  if [[ "${federated_credential_created}" == "true" ]]; then
    break
  fi

  (( ++attempt ))

  credential_create_started_at="${SECONDS}"
  set +e
  FEDERATED_CREDENTIAL_OUTPUT="$(az identity federated-credential create --subscription "${SUBSCRIPTION_NAME}" --identity-name "${MANAGED_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP_NAME}" --name "${AKS_CREDENTIAL}" --issuer "${AKS_ISSUER}" --audiences "${AKS_AUDIENCES}" --subject "${AKS_SUBJECT}" -o none 2>&1)"
  status=$?
  set -e

  if [[ ${status} -eq 0 ]]; then
    federated_credential_created=true
    echo "Federated credential create/update for ${AKS_CREDENTIAL} completed in $((SECONDS - credential_create_started_at))s on attempt ${attempt}"
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
