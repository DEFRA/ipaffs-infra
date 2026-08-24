#!/bin/bash

set -e
#set -x

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[0;37m'
readonly NC='\033[0m'
readonly BOLD='\033[1;37m'
readonly YELLOW='\033[1;33m'
readonly PURPLE='\033[0;35m'

if [[ "${BASH_VERSINFO:-0}" -lt 4 ]]; then
  echo "Error: this script requires Bash 4.0 or newer"
  exit 1
fi

function usage() {
  echo "Usage: $0 -e ENV [-w SECONDS] [-c CHECKS] [-p REQUESTS]" >&2
  echo >&2
  echo "  -e  Environment: dev, tst, pre, prd (case-insensitive)" >&2
  echo "  -w  Seconds to wait between requests (default: 5, minimum: 0)" >&2
  echo "  -c  Number of checks to perform (default: run until Q is pressed)" >&2
  echo "  -p  Parallel request limit when -w 0 is used (default: 1)" >&2
  echo >&2
}

interval=5
count=""
parallelism=1

while getopts "e:w:c:p:h" opt; do
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
    p)
      parallelism="${OPTARG}"
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

if ! [[ "${parallelism}" =~ ^[1-9][0-9]*$ ]]; then
  echo "-p must be a positive whole number" >&2
  echo >&2
  usage
  exit 1
fi

if [[ "${parallelism}" =~ ^[2-9][0-9]*$ ]] && [[ "${interval}" =~ ^[1-9][0-9]*$ ]]; then
  echo "-p can only be specified with -w 0" >&2
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

  if (( parallelism > count )); then
    echo "-p cannot be more than -c" >&2
    echo >&2
    usage
    exit 1
  fi
fi

case "${environment}" in
  dev)
    urlB2C="https://ipaffs-dev.azure.defra.cloud/notification/dev/protected/notifications"
    urlB2B="https://importnotification-int-dev.azure.defra.cloud/notification/dev/protected/notifications"
    classicPrefixB2C="https://dcidmtest.b2clogin.com"
    classicPrefixB2B="https://login.microsoftonline.com"
    aksPrefix="https://ipaffs-redirect-dev.azure.defra.cloud"
    aksLoginUrlB2C="login_url=https%3A%2F%2Fdcidmtest.b2clogin.com"
    aksLoginUrlB2B="login_url=https%3A%2F%2Flogin.microsoftonline.com"
    ;;
  tst)
    urlB2C="https://ipaffs-tst.azure.defra.cloud/notification/tst/protected/notifications"
    urlB2B="https://importnotification-int-tst.azure.defra.cloud/notification/tst/protected/notifications"
    classicPrefixB2C="https://dcidmtest.b2clogin.com"
    classicPrefixB2B="https://login.microsoftonline.com"
    aksPrefix="https://ipaffs-redirect-tst.azure.defra.cloud"
    aksLoginUrlB2C="login_url=https%3A%2F%2Fdcidmtest.b2clogin.com"
    aksLoginUrlB2B="login_url=https%3A%2F%2Flogin.microsoftonline.com"
    ;;
  pre)
    urlB2C="https://ipaffs-pre.azure.defra.cloud/notification/pre/protected/notifications"
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

request_config() {
  local url_type="$1"

  if [[ "${url_type}" == "B2C" ]]; then
    url="${urlB2C}"
    expectedClassicPrefix="${classicPrefixB2C}"
    expectedAksLoginUrl="${aksLoginUrlB2C}"
  else
    url="${urlB2B}"
    expectedClassicPrefix="${classicPrefixB2B}"
    expectedAksLoginUrl="${aksLoginUrlB2B}"
  fi
}

cookie_value() {
  local cookie_name="$1"
  local result="$2"
  local cookie_line
  cookie_line="$(printf '%s\n' "${result}" | tr -d '\r' | grep -i "^set-cookie:[[:space:]]*${cookie_name}=" | tail -1)" || true
  cookie_line="${cookie_line#*:}"
  cookie_line="${cookie_line# }"
  cookie_line="${cookie_line#*=}"
  printf '%s' "${cookie_line%%;*}"
}

write_value() {
  local path="$1"
  local value="$2"
  printf '%s' "${value}" > "${path}"
}

print_cookie_value() {
  local origin="$1"
  local cookie_name="$2"
  local value="$3"
  echo -e "${WHITE}Cookie ${cookie_name} (${origin}): ${CYAN}${value:-not set}${NC}"
}

run_request() {
  local url_type="$1"
  local output_dir="$2"
  local timestamp
  local result
  local status
  local location
  local classification
  local aslbsa
  local aslbsacors

  request_config "${url_type}"

  timestamp="$(date +"%Y-%m-%dT%H:%M:%S%z")"
  result="$(curl -is --connect-timeout 10 --max-time 15 "${url}" 2>&1)" || true
  status="$(echo "${result}" | grep "^HTTP/" | tail -1 | tr -d '\r' | cut -d' ' -f2)"
  location="$(echo "${result}" | grep -i "^location:" | tail -1 | tr -d '\r')"
  location="${location#*:}"
  location="${location# }"
  aslbsa="$(cookie_value "ASLBSA" "${result}")"
  aslbsacors="$(cookie_value "ASLBSACORS" "${result}")"

  if [[ "${status}" == "302" ]] || [[ "${status}" == "303" ]]; then
    if [[ "${location}" == "${expectedClassicPrefix}"* ]]; then
      classification="Classic"
    elif [[ "${location}" == "${aksPrefix}"* ]]; then
      classification="AKS"
    else
      classification="Unknown"
    fi
  else
    classification="Error"
  fi

  write_value "${output_dir}/timestamp" "${timestamp}"
  write_value "${output_dir}/urlType" "${url_type}"
  write_value "${output_dir}/status" "${status}"
  write_value "${output_dir}/location" "${location}"
  write_value "${output_dir}/classification" "${classification}"
  write_value "${output_dir}/expectedClassicPrefix" "${expectedClassicPrefix}"
  write_value "${output_dir}/expectedAksLoginUrl" "${expectedAksLoginUrl}"
  write_value "${output_dir}/aslbsa" "${aslbsa}"
  write_value "${output_dir}/aslbsacors" "${aslbsacors}"
}

process_request() {
  local output_dir="$1"
  local timestamp
  local urlType
  local status
  local location
  local classification
  local expectedClassicPrefix
  local expectedAksLoginUrl
  local aslbsa
  local aslbsacors
  local classif_colored
  local errorKey
  local cookieKey
  local cookieValue

  timestamp="$(<"${output_dir}/timestamp")"
  urlType="$(<"${output_dir}/urlType")"
  status="$(<"${output_dir}/status")"
  location="$(<"${output_dir}/location")"
  classification="$(<"${output_dir}/classification")"
  expectedClassicPrefix="$(<"${output_dir}/expectedClassicPrefix")"
  expectedAksLoginUrl="$(<"${output_dir}/expectedAksLoginUrl")"
  aslbsa="$(<"${output_dir}/aslbsa")"
  aslbsacors="$(<"${output_dir}/aslbsacors")"

  if [[ "${status}" == "302" ]] || [[ "${status}" == "303" ]]; then
    if [[ "${classification}" == "Classic" ]]; then
      totalClassic=$((totalClassic + 1))
      if [[ "${urlType}" == "B2C" ]]; then
        totalClassicB2C=$((totalClassicB2C + 1))
      else
        totalClassicB2B=$((totalClassicB2B + 1))
      fi
    elif [[ "${classification}" == "AKS" ]]; then
      totalAks=$((totalAks + 1))
      if [[ "${urlType}" == "B2C" ]]; then
        totalAksB2C=$((totalAksB2C + 1))
      else
        totalAksB2B=$((totalAksB2B + 1))
      fi
    else
      totalUnknown=$((totalUnknown + 1))
      totalValidationFailures=$((totalValidationFailures + 1))
    fi

    case "${classification}" in
      Classic) classif_colored="${GREEN}${classification}${NC}" ;;
      AKS)     classif_colored="${BLUE}${classification}${NC}" ;;
      *)       classif_colored="${classification}" ;;
    esac

    echo -e "${timestamp} [${urlType}] ${status} -> ${classif_colored}"

    if [[ "${classification}" == "Classic" || "${classification}" == "AKS" ]]; then
      cookieKey="${urlType}-${classification}"
      cookieValue="${aslbsa}|${aslbsacors}"
      if [[ "${cookieOriginsPrinted[${cookieKey}]:-}" == "" ]] || [[ "${cookieOriginsPrinted[${cookieKey}]}" != "V${cookieValue}" ]]; then
        print_cookie_value "${urlType} ${classification}" "ASLBSA" "${aslbsa}"
        print_cookie_value "${urlType} ${classification}" "ASLBSACORS" "${aslbsacors}"
        cookieOriginsPrinted["${cookieKey}"]="V${cookieValue}"
      fi
    fi

    if [[ "${classification}" == "AKS" ]] && [[ "${location}" != *"${expectedAksLoginUrl}"* ]]; then
      totalValidationFailures=$((totalValidationFailures + 1))
      echo -e "${RED}${timestamp} [${urlType}] Validation failure: AKS Location missing expected login_url${NC}"
      echo -e "  Received: ${YELLOW}${location}${NC}"
      echo -e "  Expected: ${PURPLE}${expectedAksLoginUrl}${NC}"
    elif [[ "${classification}" == "Unknown" ]]; then
      echo -e "${RED}${timestamp} [${urlType}] Validation failure: unexpected Location${NC}"
      echo -e "  Received: ${YELLOW}${location:-none}${NC}"
      echo -e "  Expected: ${PURPLE}${expectedClassicPrefix}${NC} or ${PURPLE}${aksPrefix}${NC}"
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
}

launch_parallel_request() {
  local request_number="$1"
  local url_type="$2"
  local output_dir="${requestsDir}/request-${request_number}"

  mkdir -p "${output_dir}"
  run_request "${url_type}" "${output_dir}" &
  pendingPids+=("$!")
  pendingDirs+=("${output_dir}")
}

process_completed_parallel_requests() {
  local had_completion=1
  local new_pids=()
  local new_dirs=()
  local i

  for i in "${!pendingPids[@]}"; do
    if kill -0 "${pendingPids[${i}]}" 2>/dev/null; then
      new_pids+=("${pendingPids[${i}]}")
      new_dirs+=("${pendingDirs[${i}]}")
    else
      wait "${pendingPids[${i}]}" || true
      process_request "${pendingDirs[${i}]}"
      completedRequests=$((completedRequests + 1))
      had_completion=0
    fi
  done

  pendingPids=("${new_pids[@]}")
  pendingDirs=("${new_dirs[@]}")
  return "${had_completion}"
}

run_serial_checks() {
  local request_number=0
  local request_dir

  while true; do
    for urlType in B2C B2B; do
      request_dir="${requestsDir}/request-${request_number}"
      mkdir -p "${request_dir}"
      run_request "${urlType}" "${request_dir}"
      process_request "${request_dir}"
      request_number=$((request_number + 1))
    done

    checksPerformed=$(( checksPerformed + 1 ))

    if [[ -n "${count}" ]] && (( checksPerformed >= count )); then
      break
    fi

    read -r -t "${read_timeout}" -N 1 input || true
    if [[ "${input}" == "q" ]] || [[ "${input}" == "Q" ]]; then
      break
    fi
  done
}

run_parallel_checks() {
  local totalRequests=""
  local nextRequest=0
  local stopScheduling=0
  local urlType

  if [[ -n "${count}" ]]; then
    totalRequests=$((count * 2))
  fi

  while true; do
    while (( ${#pendingPids[@]} < parallelism )) && (( stopScheduling == 0 )); do
      if [[ -n "${totalRequests}" ]] && (( nextRequest >= totalRequests )); then
        break
      fi

      if (( nextRequest % 2 == 0 )); then
        urlType="B2C"
      else
        urlType="B2B"
      fi

      launch_parallel_request "${nextRequest}" "${urlType}"
      nextRequest=$((nextRequest + 1))
    done

    process_completed_parallel_requests || true

    if [[ -n "${totalRequests}" ]] && (( completedRequests >= totalRequests )); then
      break
    fi

    if [[ -z "${totalRequests}" ]] && (( stopScheduling == 1 )) && (( ${#pendingPids[@]} == 0 )); then
      break
    fi

    input=""
    read -r -t 0.01 -N 1 input || true
    if [[ "${input}" == "q" ]] || [[ "${input}" == "Q" ]]; then
      stopScheduling=1
    fi
  done

  checksPerformed=$((completedRequests / 2))
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
if (( interval == 0 )); then
  echo "Parallel request limit: ${parallelism}"
fi
echo
if [[ -n "${count}" ]]; then
  echo "Performing ${count} checks"
  echo
fi
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
declare -A cookieOriginsPrinted
input=""
checksPerformed=0
completedRequests=0
pendingPids=()
pendingDirs=()
requestsDir="$(mktemp -d /tmp/routing-check.XXXXXX)"
trap 'rm -rf "${requestsDir}"' EXIT

read_timeout="${interval}"
(( interval == 0 )) && read_timeout="0.001"

pct() {
  awk -v n="$1" -v t="$2" 'BEGIN { if (t == 0) { printf "0.00" } else { printf "%.2f", (n / t) * 100 } }'
}

if (( interval == 0 && parallelism > 1 )); then
  run_parallel_checks
else
  run_serial_checks
fi

total=$(( totalClassic + totalAks + totalUnknown + totalError ))

echo
echo -e "${NC}${BOLD}=== Summary ===${NC}"
echo -e "${BOLD}Total responses: ${total} (B2C: ${totalB2C}, B2B: ${totalB2B})${NC}"
echo
echo -e "${BOLD}Classic: ${totalClassic} ($(pct "${totalClassic}" "${total}")%)${NC}"
echo -e "${BOLD}  - B2C: ${totalClassicB2C} ($(pct "${totalClassicB2C}" "${totalB2C}")%)${NC}"
echo -e "${BOLD}  - B2B: ${totalClassicB2B} ($(pct "${totalClassicB2B}" "${totalB2B}")%)${NC}"
echo -e "${BOLD}AKS:     ${totalAks} ($(pct "${totalAks}" "${total}")%)${NC}"
echo -e "${BOLD}  - B2C: ${totalAksB2C} ($(pct "${totalAksB2C}" "${totalB2C}")%)${NC}"
echo -e "${BOLD}  - B2B: ${totalAksB2B} ($(pct "${totalAksB2B}" "${totalB2B}")%)${NC}"
echo
echo -e "${BOLD}Unknown: ${totalUnknown} ($(pct "${totalUnknown}" "${total}")%)${NC}"
echo -e "${BOLD}Errors:  ${totalError} ($(pct "${totalError}" "${total}")%)${NC}"

if (( totalError > 0 )); then
  echo
  echo -e "${BOLD}Errors by status code:${NC}"
  for key in $(printf '%s\n' "${!errorCounts[@]}" | sort -V); do
    count="${errorCounts[${key}]}"
    echo -e "${BOLD}  ${key}: ${count} ($(pct "${count}" "${total}")%)${NC}"
  done
fi

if (( totalValidationFailures > 0 )); then
  echo
  echo -e "${BOLD}Validation failures: ${totalValidationFailures}${NC}"
fi
