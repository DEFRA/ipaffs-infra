#!/bin/bash

set -euo pipefail

CHART_PATH="${CHART_PATH:-helm-charts/webapp}"
HELM_UNITTEST_VERSION="${HELM_UNITTEST_VERSION:-v0.7.2}"
LINT_VALUES_FILE="${LINT_VALUES_FILE:-${CHART_PATH}/tests/ci-values.yaml}"

echo "Updating chart dependencies..."
[[ -d "${CHART_PATH}/charts" ]] && rm -r "${CHART_PATH}/charts"
[[ -f "${CHART_PATH}/Chart.lock" ]] && rm "${CHART_PATH}/Chart.lock"
helm dependency build "${CHART_PATH}" --skip-refresh

echo "Linting chart ${CHART_PATH}..."
if [[ -f "${LINT_VALUES_FILE}" ]]; then
  helm lint "${CHART_PATH}" --values "${LINT_VALUES_FILE}"
else
  helm lint "${CHART_PATH}"
fi

if ! helm plugin list | awk 'NR>1 {print $1}' | grep -qx "unittest"; then
  echo "Installing helm-unittest plugin (${HELM_UNITTEST_VERSION})..."
  helm plugin install https://github.com/helm-unittest/helm-unittest --version "${HELM_UNITTEST_VERSION}"
fi

echo "Running helm unit tests for ${CHART_PATH}..."
helm unittest --strict "${CHART_PATH}"

if [[ "${CHART_PATH}" == "helm-charts/webapp" || "${CHART_PATH}" == "helm-charts/job" ]]; then
  echo "Checking application filesystem schema enforcement..."
  render_args=()
  if [[ -f "${LINT_VALUES_FILE}" ]]; then
    render_args+=(--values "${LINT_VALUES_FILE}")
  fi
  # Establish a valid render so unrelated template failures cannot pass these tests.
  helm template filesystem-policy "${CHART_PATH}" "${render_args[@]}" >/dev/null
  overrides=(
    'container.securityContext.readOnlyRootFilesystem=false'
    'container.securityContext.readOnlyRootFilesystem=null'
    'container.securityContext=null'
    'container=null'
    'temporaryFilesystem={"enabled":false}'
    'podSecurityContext={"fsGroup":2000}'
    'volumes=[{"name":"custom","emptyDir":{}}]'
    'container.volumeMounts=[{"name":"custom","mountPath":"/"}]'
    'container.applicationInsightsSelfDiagnosticsFilePath=""'
    'config.APPLICATIONINSIGHTS_SELF_DIAGNOSTICS_FILE_PATH="/var/log/agent.log"'
  )
  for override in "${overrides[@]}"; do
    if output=$(helm template filesystem-policy "${CHART_PATH}" "${render_args[@]}" --set-json "${override}" 2>&1); then
      echo "Filesystem override was accepted: ${override}" >&2
      exit 1
    fi
    if ! grep -Fq "values don't meet the specifications of the schema" <<<"${output}"; then
      echo "Expected a schema rejection for ${override}, got: ${output}" >&2
      exit 1
    fi
  done
  echo "Rejected all ${#overrides[@]} filesystem overrides."
fi
