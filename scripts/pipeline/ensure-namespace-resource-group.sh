#!/bin/bash
#
# ensure-namespace-resource-group.sh
# For an alternative (non-default) namespace, create or reconcile its
# dedicated resource group `<BASE_RESOURCE_GROUP_NAME>-<NAMESPACE>`; for the
# environment's default namespace, just report the base resource group
# unchanged. Refuses to reuse a namespace deployed before per-namespace
# resource groups existed (see docs/namespace-resource-groups.md) or a
# resource group not tagged as owned by this pipeline.
#
# Usage (with Azure authentication and the required environment configured):
#   NAMESPACE=pr-123 DEFAULT_NAMESPACE=dev BASE_RESOURCE_GROUP_NAME=devimpinfrg1401 \
#   SUBSCRIPTION_NAME=... LOCATION=uksouth AKS_NAME=... \
#   ./ensure-namespace-resource-group.sh
#
# Required env: NAMESPACE, DEFAULT_NAMESPACE, BASE_RESOURCE_GROUP_NAME,
# SUBSCRIPTION_NAME, LOCATION, AKS_NAME.
# Outputs the ADO pipeline variable `namespaceResourceGroupName`.
#
# Requires: az (logged in), kubectl, jq. Installs its own kubelogin/kubectl
# CLI via `az aks install-cli`. Covered by
# ./ensure-namespace-resource-group.test.sh, which fakes az/kubectl/kubelogin
# and runs without Azure or a cluster.

set -euo pipefail

: "${NAMESPACE:?NAMESPACE is required}"
: "${DEFAULT_NAMESPACE:?DEFAULT_NAMESPACE is required}"
: "${BASE_RESOURCE_GROUP_NAME:?BASE_RESOURCE_GROUP_NAME is required}"
: "${SUBSCRIPTION_NAME:?SUBSCRIPTION_NAME is required}"
: "${LOCATION:?LOCATION is required}"
: "${AKS_NAME:?AKS_NAME is required}"

# Fixed, not customisable: the Helm chart's ASO ResourceGroup CR hardcodes
# this same value in spec.tags.ManagedBy, so the two must never diverge.
MANAGED_BY_TAG_VALUE="ipaffs-manifest-pipeline"

# Azure resource group names allow at most 90 characters.
AZURE_RESOURCE_GROUP_NAME_MAX_LENGTH=90

RESERVED_NAMESPACES=(dev tst pre prd)

for reserved in "${RESERVED_NAMESPACES[@]}"; do
  if [[ "${NAMESPACE}" == "${reserved}" && "${NAMESPACE}" != "${DEFAULT_NAMESPACE}" ]]; then
    echo "Namespace '${NAMESPACE}' is reserved for a different environment's default namespace and cannot be used here (this environment's default namespace is '${DEFAULT_NAMESPACE}')." >&2
    echo "Refusing to proceed before any Azure resource group is created or reconciled." >&2
    exit 1
  fi
done

# Before any Azure mutation, authenticate against the AKS cluster and check
# for a namespace that was deployed before per-namespace resource groups
# existed: an alternative namespace with a Helm 'bootstrap' release but no
# matching ASO ResourceGroup CR must be recreated, not silently reused.
# kubectl/jq failures fail closed rather than being treated as "safe to
# proceed".
check_for_legacy_namespace_deployment() {
  local namespace="$1"
  local namespace_resource_group_k8s_name="$2"

  echo "Authenticating kubectl against the ${AKS_NAME} AKS cluster to check for a legacy deployment in namespace '${namespace}'"
  az aks install-cli --client-version v1.36.1 --kubelogin-version v0.2.18
  if ! az aks get-credentials \
    --name "${AKS_NAME}" \
    --resource-group "${BASE_RESOURCE_GROUP_NAME}" \
    --subscription "${SUBSCRIPTION_NAME}" \
    --overwrite-existing; then
    echo "Unable to authenticate against AKS cluster '${AKS_NAME}'; refusing to proceed without checking for a legacy namespace deployment." >&2
    exit 1
  fi

  if command -v kubelogin >/dev/null 2>&1; then
    kubelogin convert-kubeconfig -l azurecli
  fi

  local namespace_check_output
  if ! namespace_check_output="$(kubectl get namespace "${namespace}" -o name --ignore-not-found 2>&1)"; then
    echo "Unable to determine whether namespace '${namespace}' exists:" >&2
    echo "${namespace_check_output}" >&2
    echo "Refusing to proceed: kubectl checks must succeed before any Azure resource group is created or reconciled." >&2
    exit 1
  fi

  if [[ -z "${namespace_check_output}" ]]; then
    echo "Namespace '${namespace}' does not exist yet; nothing to check for a legacy deployment"
    return 0
  fi

  local resource_groups_json
  if ! resource_groups_json="$(kubectl get resourcegroups.resources.azure.com --namespace "${namespace}" -o json 2>&1)"; then
    echo "Unable to list ASO ResourceGroup resources in namespace '${namespace}':" >&2
    echo "${resource_groups_json}" >&2
    echo "Refusing to proceed: kubectl checks must succeed before any Azure resource group is created or reconciled." >&2
    exit 1
  fi

  if ! jq -e '.items | type == "array"' <<<"${resource_groups_json}" >/dev/null 2>&1; then
    echo "ASO ResourceGroup list for namespace '${namespace}' returned an unexpected response; refusing to proceed." >&2
    exit 1
  fi

  if jq -e --arg name "${namespace_resource_group_k8s_name}" '.items | any(.metadata.name == $name)' <<<"${resource_groups_json}" >/dev/null 2>&1; then
    echo "Namespace '${namespace}' already has an ASO ResourceGroup '${namespace_resource_group_k8s_name}'; this is an idempotent update"
    return 0
  fi

  if [[ "$(jq '.items | length' <<<"${resource_groups_json}")" -gt 0 ]]; then
    echo "Namespace '${namespace}' already has ASO ResourceGroup resource(s) but not the expected dedicated resource group '${namespace_resource_group_k8s_name}'." >&2
    echo "This means '${namespace}' is an alternative namespace that existed before per-namespace resource groups were introduced." >&2
    echo "Refusing to reuse this namespace: it must be recreated, not migrated. Delete the stale namespace and any Azure resources it owns in the shared resource group '${BASE_RESOURCE_GROUP_NAME}' (its Service Bus namespace, Redis cache and managed identities, named with the '${BASE_RESOURCE_GROUP_NAME}-${namespace}' / '...-${namespace}-...' prefixes), then redeploy so a freshly tagged resource group and resources are created." >&2
    exit 1
  fi

  # No ASO ResourceGroup at all: check for a prior Helm 'bootstrap' release
  # via its release Secret metadata directly through kubectl (avoiding a
  # dependency on the helm CLI). Only labels/names are inspected, never the
  # Secret's data (the compressed release manifest), so nothing sensitive is
  # logged.
  local bootstrap_release_secrets_json
  if ! bootstrap_release_secrets_json="$(kubectl get secrets --namespace "${namespace}" -l "owner=helm,name=bootstrap" -o json 2>&1)"; then
    echo "Unable to determine whether namespace '${namespace}' already has a Helm 'bootstrap' deployment:" >&2
    echo "${bootstrap_release_secrets_json}" >&2
    echo "Refusing to proceed: kubectl checks must succeed before any Azure resource group is created or reconciled." >&2
    exit 1
  fi

  if ! jq -e '.items | type == "array"' <<<"${bootstrap_release_secrets_json}" >/dev/null 2>&1; then
    echo "Helm release secret list for namespace '${namespace}' returned an unexpected response; refusing to proceed." >&2
    exit 1
  fi

  if [[ "$(jq '.items | length' <<<"${bootstrap_release_secrets_json}")" -gt 0 ]]; then
    echo "Namespace '${namespace}' already has a Helm 'bootstrap' deployment but no ASO ResourceGroup '${namespace_resource_group_k8s_name}'." >&2
    echo "This means '${namespace}' is an alternative namespace that existed before per-namespace resource groups were introduced." >&2
    echo "Refusing to reuse this namespace: it must be recreated, not migrated. Delete the stale namespace and any Azure resources it owns in the shared resource group '${BASE_RESOURCE_GROUP_NAME}' (its Service Bus namespace, Redis cache and managed identities, named with the '${BASE_RESOURCE_GROUP_NAME}-${namespace}' / '...-${namespace}-...' prefixes), then redeploy so a freshly tagged resource group and resources are created." >&2
    exit 1
  fi

  echo "Namespace '${namespace}' exists but has no Helm 'bootstrap' deployment or ASO ResourceGroup; treating as a fresh, empty namespace"
}

if [[ "${NAMESPACE}" == "${DEFAULT_NAMESPACE}" ]]; then
  echo "Namespace '${NAMESPACE}' is the default namespace for this environment; using the existing resource group ${BASE_RESOURCE_GROUP_NAME}"
  namespace_resource_group_name="${BASE_RESOURCE_GROUP_NAME}"
else
  if ! [[ "${NAMESPACE}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    echo "Namespace '${NAMESPACE}' is invalid. Use lowercase alphanumeric and '-' only." >&2
    exit 1
  fi

  if [[ ${#NAMESPACE} -gt 63 ]]; then
    echo "Namespace '${NAMESPACE}' exceeds 63 characters" >&2
    exit 1
  fi

  namespace_resource_group_name="${BASE_RESOURCE_GROUP_NAME}-${NAMESPACE}"

  if [[ ${#namespace_resource_group_name} -gt ${AZURE_RESOURCE_GROUP_NAME_MAX_LENGTH} ]]; then
    echo "Resource group name '${namespace_resource_group_name}' exceeds the ${AZURE_RESOURCE_GROUP_NAME_MAX_LENGTH} character Azure limit" >&2
    exit 1
  fi

  namespace_resource_group_k8s_name="$(echo "${namespace_resource_group_name}" | tr '[:upper:]' '[:lower:]')"
  check_for_legacy_namespace_deployment "${NAMESPACE}" "${namespace_resource_group_k8s_name}"

  echo "Checking for an existing resource group '${namespace_resource_group_name}'"
  set +e
  existing_rg_json="$(az group show --name "${namespace_resource_group_name}" --subscription "${SUBSCRIPTION_NAME}" -o json 2>&1)"
  show_status=$?
  set -e

  if [[ ${show_status} -eq 0 ]]; then
    existing_managed_by="$(jq -r '.tags.ManagedBy // ""' <<<"${existing_rg_json}")"
    existing_namespace_tag="$(jq -r '.tags.Namespace // ""' <<<"${existing_rg_json}")"
    existing_base_tag="$(jq -r '.tags.BaseResourceGroup // ""' <<<"${existing_rg_json}")"

    if [[ "${existing_managed_by}" != "${MANAGED_BY_TAG_VALUE}" || "${existing_namespace_tag}" != "${NAMESPACE}" || "${existing_base_tag}" != "${BASE_RESOURCE_GROUP_NAME}" ]]; then
      echo "Resource group '${namespace_resource_group_name}' already exists but is not tagged as owned by this pipeline for namespace '${NAMESPACE}' (found ManagedBy='${existing_managed_by}', Namespace='${existing_namespace_tag}', BaseResourceGroup='${existing_base_tag}')." >&2
      echo "Refusing to modify a resource group that may belong to something else." >&2
      echo "This usually means '${NAMESPACE}' is an alternative namespace that existed before per-namespace resource groups were introduced, or the resource group name collides with something unrelated." >&2
      echo "Alternative namespaces from before this change must be recreated, not migrated: delete the stale namespace and any Azure resources it owns in the shared resource group '${BASE_RESOURCE_GROUP_NAME}' (its Service Bus namespace, Redis cache and managed identities, named with the '${BASE_RESOURCE_GROUP_NAME}-${NAMESPACE}' / '...-${NAMESPACE}-...' prefixes), then redeploy so a freshly tagged resource group and resources are created." >&2
      exit 1
    fi

    echo "Resource group '${namespace_resource_group_name}' already exists and is owned by this pipeline for namespace '${NAMESPACE}'; reconciling"
  else
    if ! grep -qiE "could not be found|ResourceGroupNotFound" <<<"${existing_rg_json}"; then
      echo "Unable to determine whether resource group '${namespace_resource_group_name}' exists:" >&2
      echo "${existing_rg_json}" >&2
      exit 1
    fi

    echo "Resource group '${namespace_resource_group_name}' does not exist; creating"
  fi

  az group create \
    --name "${namespace_resource_group_name}" \
    --location "${LOCATION}" \
    --subscription "${SUBSCRIPTION_NAME}" \
    --tags "ManagedBy=${MANAGED_BY_TAG_VALUE}" "Namespace=${NAMESPACE}" "BaseResourceGroup=${BASE_RESOURCE_GROUP_NAME}" \
    -o none
fi

echo "Using namespace resource group: ${namespace_resource_group_name}"
echo "##vso[task.setvariable variable=namespaceResourceGroupName;isOutput=true]${namespace_resource_group_name}"
echo "##vso[task.setvariable variable=namespaceResourceGroupName]${namespace_resource_group_name}"
