#!/bin/bash

set -eux

if [[ "${BRANCH}" == "${TRUNK}" ]]; then
  namespace="$(echo "${ENVIRONMENT}" | tr '[:upper:]' '[:lower:]')"
else
  encodedBranch="$(echo -n "${BRANCH}" | base64 | tr -d '=')"
  namespace="$(kubectl get namespace -l "defra.gov.uk/branch=${encodedBranch}" -o json | jq -r '.items[0].metadata.name')"
fi

if [[ "${namespace}" == "" ]] || [[ "${namespace}" == "null" ]]; then
  echo "No namespace found for branch \`${BRANCH}\`" >&2
  exit 1
fi

echo "##vso[task.setvariable variable=namespace;isOutput=true]${namespace}"

# vim: set ts=2 sts=2 sw=2 et:
