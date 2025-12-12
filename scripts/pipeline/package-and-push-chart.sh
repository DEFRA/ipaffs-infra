#!/bin/bash

set -eux

echo Logging in to ACR..
az acr login --name "${REGISTRY_NAME}"

echo Updating chart dependencies...
[[ -d "${CHART_PATH}/charts" ]] && rm -r "${CHART_PATH}/charts"
[[ -f "${CHART_PATH}/Chart.lock" ]] && rm "${CHART_PATH}/Chart.lock"
helm dependency update "${CHART_PATH}"

echo Packaging Helm Chart...
helm package "${CHART_PATH}" --version "${CHART_VERSION}"

echo Pushing Helm chart to ACR...
helm push "${CHART_NAME}-${CHART_VERSION}.tgz" "oci://${REGISTRY_HOST}/helm/v1/repo"

# vim: set ts=2 sts=2 sw=2 et:
