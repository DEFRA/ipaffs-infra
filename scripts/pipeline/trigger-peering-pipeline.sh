#!/bin/bash

set -ux

adoProject="CCoE-Infrastructure"
peeringPipelineId=1851

runResult="$(az pipelines run \
  --org "${ADO_ORG_URL}" \
  --project "${adoProject}" \
  --id "${peeringPipelineId}" \
  --parameters VirtualNetworkName=${VNET_NAME} Subscription=${SUBSCRIPTION_NAME} Tenant=$(TENANT_ID) PeerToSec=false)"

[[ $? -ne 0 ]] && exit 1

runId="$(echo "${runResult}" | jq -r '.id')"
if [[ "${runId}" == "" ]]; then
  echo "Could not determine ID for triggered pipeline build" >&2
  exit 1
fi

startTime="$(date -u +%s)"
status=
while true; do
  sleep 5
  status="$(az pipelines runs show --org "${ADO_ORG_URL}" --project "${adoProject}" --id "${runId}" | jq -r '.status')"
  [[ "${status}" == "completed" ]] && break
  curTime="$(date -u +%s)"
  elapsed="$(( $curTime - $startTime ))"
  if (( $elapsed > 600 )); then
    echo "Timed out waiting for peering pipeline to complete" >&2
    exit 1
  fi
done

result="$(az pipelines runs show --org "${ADO_ORG_URL}" --project "${adoProject}" --id "${runId}" | jq -r '.result')"
echo "Peering pipeline result: ${result}"
case "${result}" in
  canceled)
    exit 1
    ;;
  failed)
    exit 1
    ;;
  succeeded)
    exit 0
    ;;
  *)
    exit 3
    ;;
esac

# vim: set ts=2 sts=2 sw=2 et:
