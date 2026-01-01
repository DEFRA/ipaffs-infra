#!/bin/bash

set -eux

pipelineId="$(az pipelines show --org https://dev.azure.com/defragovuk/ --project DEFRA-EUTD-IPAFFS --folder-path "${FOLDER}" --name "${PIPELINE}" --query 'id')"
latestBuildId="$(az pipelines runs list --org https://dev.azure.com/defragovuk/ --project DEFRA-EUTD-IPAFFS --query-order FinishTimeDesc --result succeeded --status completed --pipeline-ids "${pipelineId}" --branch "${BRANCH}")"

echo "##vso[task.setvariable variable=version;isOutput=true]${latestBuildId}"
