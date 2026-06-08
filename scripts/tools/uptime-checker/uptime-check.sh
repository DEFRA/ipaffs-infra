#!/bin/bash

set -e
#set -x

if [[ "${BASH_VERSINFO:-0}" -lt 4 ]]; then
  echo "Error: this script requires Bash 4.0 or newer"
fi

function usage() {
  echo "Usage: $0 -e ENV" >&2
  echo >&2
  echo "  -e  Specify environment to check" >&2
  echo >&2
}

while getopts "e:h" opt; do
  case $opt in
    e)
      environment="${OPTARG}"
      ;;
    \?)
      usage
      exit 0
      ;;
  esac
done

if [[ -z "${environment}" ]]; then
  echo "-e is a required argument" >&2
  echo >&2
  usage
  exit 1
fi

declare -a ipaffsDomains

case "${environment}" in
  dev)
    ipaffsDomains+=("importnotification-dev.azure.defra.cloud" "importnotification-int-dev.azure.defra.cloud")
    ;;
  tst)
    ipaffsDomains+=("importnotification-tst.azure.defra.cloud" "importnotification-int-tst.azure.defra.cloud")
    ;;
  pre)
    ipaffsDomains+=("importnotification-pre.azure.defra.cloud" "importnotification-int-pre.azure.defra.cloud")
    ;;
  prd)
    ipaffsDomains+=("import-products-animals-food-feed.service.gov.uk" "importnotification-prd.azure.defra.cloud" "importnotification-int-prd.azure.defra.cloud")
    ;;
esac

echo "Checking the following domains: ${ipaffsDomains[@]}"
echo
echo "Press Q to stop checking..."
echo

totalSuccessAppGw=0
totalFailureAppGw=0
totalSuccessAfd=0
totalFailureAfd=0

while true; do
  for i in "${!ipaffsDomains[@]}"; do
    domain="${ipaffsDomains[i]}"
    url="https://${domain}/notification/${environment}/protected/notifications"
    result="$(curl -is "${url}")"
    status="$(echo "${result}" | grep "^HTTP/" | cut -d' ' -f2)"
    timestamp="$(date +"%Y-%m-%dT%H:%M:%S%z")"
    if echo "${result}" | grep -q "^x-azure-ref"; then
      if [[ "${status}" == "303" ]]; then
        totalSuccessAfd=$((totalSuccessAfd + 1))
        echo "${timestamp} Request via AFD was successful for ${domain}"
      else
        totalFailureAfd=$((totalFailureAfd + 1))
        echo "${timestamp} Request via AFD failed for ${domain}"
      fi
    else
      if [[ "${status}" == "303" ]]; then
        totalSuccessAppGw=$((totalSuccessAppGw + 1))
        echo "${timestamp} Request via AppGw was successful for ${domain}"
      else
        totalFailureAppGw=$((totalFailureAppGw + 1))
        echo "${timestamp} Request via AppGw failed for ${domain}"
      fi
    fi
  done

  read -t 5 -N 1 input || true
  if [[ "${input}" == "q" ]] || [[ "${input}" == "Q" ]]; then
    break
  fi
done

echo
echo "Total Successes (AFD): ${totalSuccessAfd}"
echo "Total Successes (AppoGw): ${totalSuccessAppGw}"
echo "Total Failures (AFD): ${totalFailureAfd}"
echo "Total Failures (AppoGw): ${totalFailureAppGw}"
