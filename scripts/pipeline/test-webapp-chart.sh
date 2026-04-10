#!/bin/bash

set -euo pipefail

CHART_PATH="${CHART_PATH:-helm-charts/webapp}"
HELM_UNITTEST_VERSION="${HELM_UNITTEST_VERSION:-v0.7.2}"
LINT_VALUES_FILE="${LINT_VALUES_FILE:-${CHART_PATH}/tests/ci-values.yaml}"

echo "Updating chart dependencies..."
[[ -d "${CHART_PATH}/charts" ]] && rm -r "${CHART_PATH}/charts"
[[ -f "${CHART_PATH}/Chart.lock" ]] && rm "${CHART_PATH}/Chart.lock"
helm dependency build "${CHART_PATH}" --skip-refresh

echo "Linting webapp chart..."
if [[ -f "${LINT_VALUES_FILE}" ]]; then
  helm lint "${CHART_PATH}" --values "${LINT_VALUES_FILE}"
else
  helm lint "${CHART_PATH}"
fi

if ! helm plugin list | awk 'NR>1 {print $1}' | grep -qx "unittest"; then
  echo "Installing helm-unittest plugin (${HELM_UNITTEST_VERSION})..."
  helm plugin install https://github.com/helm-unittest/helm-unittest --version "${HELM_UNITTEST_VERSION}"
fi

echo "Running webapp helm unit tests..."
helm unittest --strict "${CHART_PATH}"

# vim: set ts=2 sts=2 sw=2 et:
