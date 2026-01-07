#!/bin/bash

set -eux

pipelineId="$(az pipelines show --org https://dev.azure.com/defragovuk/ --project DEFRA-EUTD-IPAFFS --folder-path "${FOLDER}" --name "${PIPELINE}" --query 'id')"
latestBuildId="$(az pipelines runs list --org https://dev.azure.com/defragovuk/ --project DEFRA-EUTD-IPAFFS --query-order FinishTimeDesc --result succeeded --status completed --top 1 --pipeline-ids "${pipelineId}" --branch "${BRANCH}" --query '[0].buildNumber')"

if [[ "${latestBuildId}" == "" ]]; then
  echo "No build was found" >&2
  exit 1
fi

set +x
echo "##vso[task.setvariable variable=version;isOutput=true]${latestBuildId}"
