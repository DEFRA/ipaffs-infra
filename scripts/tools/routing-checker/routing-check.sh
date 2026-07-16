#!/bin/bash

set -e
#set -x

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'
readonly BOLD='\033[1m'

if [[ "${BASH_VERSINFO:-0}" -lt 4 ]]; then
  echo "Error: this script requires Bash 4.0 or newer"
  exit 1
fi

function usage() {
  echo "Usage: $0 -e ENV [-w SECONDS] [-c CHECKS]" >&2
  echo >&2
  echo "  -e  Environment: dev, tst, pre, prd (case-insensitive)" >&2
  echo "  -w  Seconds to wait between requests (default: 5, minimum: 0)" >&2
  echo "  -c  Number of checks to perform (default: run until Q is pressed)" >&2
  echo >&2
}

interval=5
count=""

while getopts "e:w:c:h" opt; do
  case $opt in
    e)
      environment="${OPTARG,,}"
      ;;
    w)
      interval="${OPTARG}"
      ;;
    c)
      count="${OPTARG}"
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

if [[ -n "${count}" ]]; then
  if ! [[ "${count}" =~ ^[1-9][0-9]*$ ]]; then
    echo "-c must be a positive whole number" >&2
    echo >&2
    usage
    exit 1
  fi
fi

case "${environment}" in
  dev)
    urlB2C="https://importnotification-dev.azure.defra.cloud/notification/dev/protected/notifications"
    urlB2B="https://importnotification-int-dev.azure.defra.cloud/notification/dev/protected/notifications"
    classicPrefixB2C="https://dcidmtest.b2clogin.com"
    classicPrefixB2B="https://login.microsoftonline.com"
    aksPrefix="https://ipaffs-redirect-dev.azure.defra.cloud"
    aksLoginUrlB2C="login_url=https%3A%2F%2Fdcidmtest.b2clogin.com"
    aksLoginUrlB2B="login_url=https%3A%2F%2Flogin.microsoftonline.com"
    ;;
  tst)
    urlB2C="https://importnotification-tst.azure.defra.cloud/notification/tst/protected/notifications"
    urlB2B="https://importnotification-int-tst.azure.defra.cloud/notification/tst/protected/notifications"
    classicPrefixB2C="https://dcidmtest.b2clogin.com"
    classicPrefixB2B="https://login.microsoftonline.com"
    aksPrefix="https://ipaffs-redirect-tst.azure.defra.cloud"
    aksLoginUrlB2C="login_url=https%3A%2F%2Fdcidmtest.b2clogin.com"
    aksLoginUrlB2B="login_url=https%3A%2F%2Flogin.microsoftonline.com"
    ;;
  pre)
    urlB2C="https://importnotification-pre.azure.defra.cloud/notification/pre/protected/notifications"
    urlB2B="https://importnotification-int-pre.azure.defra.cloud/notification/pre/protected/notifications"
    classicPrefixB2C="https://dcidmpreprod.b2clogin.com"
    classicPrefixB2B="https://login.microsoftonline.com"
    aksPrefix="https://ipaffs-redirect-pre.azure.defra.cloud"
    aksLoginUrlB2C="login_url=https%3A%2F%2Fdcidmpreprod.b2clogin.com"
    aksLoginUrlB2B="login_url=https%3A%2F%2Flogin.microsoftonline.com"
    ;;
  prd)
    urlB2C="https://import-products-animals-food-feed.service.gov.uk/notification/prd/protected/notifications"
    urlB2B="https://importnotification-int-prd.azure.defra.cloud/notification/prd/protected/notifications"
    classicPrefixB2C="https://dcidm.b2clogin.com"
    classicPrefixB2B="https://login.microsoftonline.com"
    aksPrefix="https://ipaffs-redirect-prd.azure.defra.cloud"
    aksLoginUrlB2C="login_url=https%3A%2F%2Fdcidm.b2clogin.com"
    aksLoginUrlB2B="login_url=https%3A%2F%2Flogin.microsoftonline.com"
    ;;
  *)
    echo "Unknown environment: ${environment}" >&2
    echo >&2
    usage
    exit 1
    ;;
esac

dns_lookup() {
  local domain="$1"
  local output
  output="$(nslookup "${domain}" 2>/dev/null)" || true
  local ips
  ips="$(printf '%s\n' "${output}" | awk '/^Name:/{found=1} found && /^Address:/{ips=ips (ips?", ":"") $2} END{print ips}')"
  printf '%s' "${ips:-unresolved}"
}

domainB2C="${urlB2C#https://}"
domainB2C="${domainB2C%%/*}"
domainB2B="${urlB2B#https://}"
domainB2B="${domainB2B%%/*}"

echo "Checking B2C: ${urlB2C}"
echo "B2C domain: ${domainB2C}"
echo "B2C resolved IP address(es): $(dns_lookup "${domainB2C}")"
echo "Checking B2B: ${urlB2B}"
echo "B2B domain: ${domainB2B}"
echo "B2B resolved IP address(es): $(dns_lookup "${domainB2B}")"
echo "Wait between requests: ${interval}s"
echo
echo "Press Q to stop..."
echo

totalClassic=0
totalClassicB2C=0
totalClassicB2B=0
totalAks=0
totalAksB2C=0
totalAksB2B=0
totalUnknown=0
totalError=0
totalValidationFailures=0
totalB2C=0
totalB2B=0
declare -A errorCounts
input=""
checksPerformed=0

read_timeout="${interval}"
(( interval == 0 )) && read_timeout="0.001"

pct() {
  awk -v n="$1" -v t="$2" 'BEGIN { if (t == 0) { printf "0.00" } else { printf "%.2f", (n / t) * 100 } }'
}

while true; do
  for urlType in B2C B2B; do
    if [[ "${urlType}" == "B2C" ]]; then
      url="${urlB2C}"
      expectedClassicPrefix="${classicPrefixB2C}"
      expectedAksLoginUrl="${aksLoginUrlB2C}"
    else
      url="${urlB2B}"
      expectedClassicPrefix="${classicPrefixB2B}"
      expectedAksLoginUrl="${aksLoginUrlB2B}"
    fi

    timestamp="$(date +"%Y-%m-%dT%H:%M:%S%z")"
    result="$(curl -is --connect-timeout 10 --max-time 15 "${url}" 2>&1)" || true
    status="$(echo "${result}" | grep "^HTTP/" | tail -1 | tr -d '\r' | cut -d' ' -f2)"
    location="$(echo "${result}" | grep -i "^location:" | tail -1 | tr -d '\r')"
    location="${location#*:}"
    location="${location# }"

    if [[ "${status}" == "302" ]] || [[ "${status}" == "303" ]]; then
      if [[ "${location}" == "${expectedClassicPrefix}"* ]]; then
        classification="Classic"
        totalClassic=$((totalClassic + 1))
        if [[ "${urlType}" == "B2C" ]]; then
          totalClassicB2C=$((totalClassicB2C + 1))
        else
          totalClassicB2B=$((totalClassicB2B + 1))
        fi
      elif [[ "${location}" == "${aksPrefix}"* ]]; then
        classification="AKS"
        totalAks=$((totalAks + 1))
        if [[ "${urlType}" == "B2C" ]]; then
          totalAksB2C=$((totalAksB2C + 1))
        else
          totalAksB2B=$((totalAksB2B + 1))
        fi
      else
        classification="Unknown"
        totalUnknown=$((totalUnknown + 1))
        totalValidationFailures=$((totalValidationFailures + 1))
      fi
      case "${classification}" in
        Classic) classif_colored="${GREEN}${classification}${NC}" ;;
        AKS)     classif_colored="${BLUE}${classification}${NC}" ;;
        *)       classif_colored="${classification}" ;;
      esac
      echo -e "${timestamp} [${urlType}] ${status} -> ${classif_colored}"
      if [[ "${classification}" == "AKS" ]] && [[ "${location}" != *"${expectedAksLoginUrl}"* ]]; then
        totalValidationFailures=$((totalValidationFailures + 1))
        echo -e "${RED}${timestamp} [${urlType}] Validation failure: AKS Location missing ${expectedAksLoginUrl}${NC}"
      elif [[ "${classification}" == "Unknown" ]]; then
        echo -e "${RED}${timestamp} [${urlType}] Validation failure: unexpected Location: ${location:-none}${NC}"
      fi
    else
      totalError=$((totalError + 1))
      errorKey="${status:-none}"
      errorCounts["${errorKey}"]=$(( ${errorCounts["${errorKey}"]:-0} + 1 ))
      echo -e "${RED}${timestamp} [${urlType}] Unexpected response: status=${status:-none}${NC}"
    fi

    if [[ "${urlType}" == "B2C" ]]; then
      totalB2C=$((totalB2C + 1))
    else
      totalB2B=$((totalB2B + 1))
    fi
  done

  checksPerformed=$(( checksPerformed + 1 ))

  if [[ -n "${count}" ]] && (( checksPerformed >= count )); then
    break
  fi

  read -t "${read_timeout}" -N 1 input || true
  if [[ "${input}" == "q" ]] || [[ "${input}" == "Q" ]]; then
    break
  fi
done

total=$(( totalClassic + totalAks + totalUnknown + totalError ))

echo
echo -e "${NC}${BOLD}=== Summary ===${NC}"
echo -e "${BOLD}Total responses: ${total} (B2C: ${totalB2C}, B2B: ${totalB2B})${NC}"
echo
echo -e "${BOLD}Classic: ${totalClassic} ($(pct ${totalClassic} ${total})%)${NC}"
echo -e "${BOLD}  - B2C: ${totalClassicB2C} ($(pct ${totalClassicB2C} ${totalB2C})%)${NC}"
echo -e "${BOLD}  - B2B: ${totalClassicB2B} ($(pct ${totalClassicB2B} ${totalB2B})%)${NC}"
echo -e "${BOLD}AKS:     ${totalAks} ($(pct ${totalAks} ${total})%)${NC}"
echo -e "${BOLD}  - B2C: ${totalAksB2C} ($(pct ${totalAksB2C} ${totalB2C})%)${NC}"
echo -e "${BOLD}  - B2B: ${totalAksB2B} ($(pct ${totalAksB2B} ${totalB2B})%)${NC}"
echo
echo -e "${BOLD}Unknown: ${totalUnknown} ($(pct ${totalUnknown} ${total})%)${NC}"
echo -e "${BOLD}Errors:  ${totalError} ($(pct ${totalError} ${total})%)${NC}"

if (( totalError > 0 )); then
  echo
  echo -e "${BOLD}Errors by status code:${NC}"
  for key in $(printf '%s\n' "${!errorCounts[@]}" | sort -V); do
    count="${errorCounts[${key}]}"
    echo -e "${BOLD}  ${key}: ${count} ($(pct ${count} ${total})%)${NC}"
  done
fi

if (( totalValidationFailures > 0 )); then
  echo
  echo -e "${BOLD}Validation failures: ${totalValidationFailures}${NC}"
fi
