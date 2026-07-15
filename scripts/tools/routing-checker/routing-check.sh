#!/bin/bash

set -e
#set -x

if [[ "${BASH_VERSINFO:-0}" -lt 4 ]]; then
  echo "Error: this script requires Bash 4.0 or newer"
  exit 1
fi

function usage() {
  echo "Usage: $0 -e ENV [-w SECONDS]" >&2
  echo >&2
  echo "  -e  Environment: dev, tst, pre, prd (case-insensitive)" >&2
  echo "  -w  Seconds to wait between requests (default: 5, minimum: 0)" >&2
  echo >&2
}

interval=5

while getopts "e:w:h" opt; do
  case $opt in
    e)
      environment="${OPTARG,,}"
      ;;
    w)
      interval="${OPTARG}"
      ;;
    h)
      usage
      exit 0
      ;;
    \?)
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${environment}" ]]; then
  echo "-e is a required argument" >&2
  echo >&2
  usage
  exit 1
fi

if ! [[ "${interval}" =~ ^[0-9]+$ ]]; then
  echo "-w must be a whole number of seconds, minimum 0" >&2
  echo >&2
  usage
  exit 1
fi

case "${environment}" in
  dev)
    url="https://importnotification-dev.azure.defra.cloud/notification/dev/protected/notifications"
    ;;
  tst)
    url="https://importnotification-tst.azure.defra.cloud/notification/tst/protected/notifications"
    ;;
  pre)
    url="https://importnotification-pre.azure.defra.cloud/notification/pre/protected/notifications"
    ;;
  prd)
    url="https://import-products-animals-food-feed.service.gov.uk/notification/prd/protected/notifications"
    ;;
  *)
    echo "Unknown environment: ${environment}" >&2
    echo >&2
    usage
    exit 1
    ;;
esac

echo "Checking: ${url}"
echo "Wait between requests: ${interval}s"
echo
echo "Press Q to stop..."
echo

totalClassic=0
totalAks=0
totalUnknown=0
totalError=0
declare -A errorCounts
input=""

pct() {
  awk -v n="$1" -v t="${total}" 'BEGIN { if (t == 0) { printf "0.00" } else { printf "%.2f", (n / t) * 100 } }'
}

while true; do
  timestamp="$(date +"%Y-%m-%dT%H:%M:%S%z")"
  result="$(curl -is --connect-timeout 10 --max-time 15 "${url}" 2>&1)" || true
  status="$(echo "${result}" | grep "^HTTP/" | tail -1 | tr -d '\r' | cut -d' ' -f2)"
  location="$(echo "${result}" | grep -i "^location:" | tail -1 | tr -d '\r')"
  location="${location#*:}"
  location="${location# }"

  if [[ "${status}" == "302" ]] || [[ "${status}" == "303" ]]; then
    if [[ "${location}" == https://dcidmtest.b2clogin.com* ]] || \
       [[ "${location}" == https://login.microsoftonline.com* ]]; then
      classification="Classic"
      totalClassic=$((totalClassic + 1))
    elif [[ "${location}" == https://ipaffs-redirect-tst.azure.defra.cloud* ]]; then
      classification="AKS"
      totalAks=$((totalAks + 1))
    else
      classification="Unknown (location: ${location:-none})"
      totalUnknown=$((totalUnknown + 1))
    fi
    echo "${timestamp} ${status} -> ${classification}"
  else
    totalError=$((totalError + 1))
    errorKey="${status:-none}"
    errorCounts["${errorKey}"]=$(( ${errorCounts["${errorKey}"]:-0} + 1 ))
    echo "${timestamp} Unexpected response: status=${status:-none}"
  fi

  if (( 10#${interval} == 0 )); then
    if read -r -t 0; then
      read -r -N 1 input || true
    fi
  else
    read -r -t "${interval}" -N 1 input || true
  fi

  if [[ "${input}" == "q" ]] || [[ "${input}" == "Q" ]]; then
    break
  fi
  input=""
done

total=$(( totalClassic + totalAks + totalUnknown + totalError ))

echo
echo "=== Summary ==="
echo "Total responses: ${total}"
echo
echo "Classic: ${totalClassic} ($(pct ${totalClassic})%)"
echo "AKS:     ${totalAks} ($(pct ${totalAks})%)"
echo "Unknown: ${totalUnknown} ($(pct ${totalUnknown})%)"
echo "Errors:  ${totalError} ($(pct ${totalError})%)"

if (( totalError > 0 )); then
  echo
  echo "Errors by status code:"
  for key in $(printf '%s\n' "${!errorCounts[@]}" | sort -V); do
    count="${errorCounts[${key}]}"
    echo "  ${key}: ${count} ($(pct ${count})%)"
  done
fi
