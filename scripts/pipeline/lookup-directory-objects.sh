#!/bin/bash

set -x

SCRIPTS_DIR="$(cd "$(dirname $0)"/.. && pwd)"

output=oid
objectType=

while getopts "o:t:" opt; do
  case $opt in
    o)
      output="${OPTARG}"
      ;;
    t)
      objectType="${OPTARG}"
      ;;
  esac
done

if [[ "${objectType}" == "" ]]; then
  echo "Must specify object type" >&2
  exit 1
fi

getODataUri() {
  local oid="${1}"
  if [[ "${oid}" == "" ]]; then
      echo "Invalid object ID specified" >&2
      exit 1
  fi

  case "${objectType}" in
    group)
      echo "https://graph.microsoft.com/v1.0/groups/${oid}"
      ;;
    servicePrincipal)
      echo "https://graph.microsoft.com/v1.0/servicePrincipals/${oid}"
      ;;
    user)
      echo "https://graph.microsoft.com/v1.0/users/${oid}"
      ;;
    *)
      echo "Invalid objectType specified: \`${OBJECT_TYPE}\`" >&2
      exit 1
      ;;
  esac
}

# Parse names (can be UPNs for users, or displayNames for groups/service principals)
declare -a names
if [[ -n "${NAMES}" ]]; then
  cleanNames="$(echo "${NAMES}" | tr -d '\n')"
  IFS=' ' read -ra names <<<"${cleanNames}"
fi

# Output members
oids=
odataUris=
for i in "${!names[@]}"; do
  name="$(echo "${names[i]}" | awk '{$1=$1};1')"
  [[ "${name}" == "" ]] && continue

  oid="$(OBJECT_NAME="${name}" OBJECT_TYPE="${objectType}" "${SCRIPTS_DIR}/pipeline/lookup-directory-object.sh" -o oid)"
  [[ $? -ne 0 ]] && exit 1
  odataUri="$(getODataUri "${oid}")"
  [[ $? -ne 0 ]] && exit 1

  oids="${oids} ${oid}"
  odataUris="${odataUris} ${odataUri}"
done

case "${output}" in
  oid)
    set +x
    echo "${oids}"
    ;;
  odataUri|odataUris)
    set +x
    echo "${odataUris}"
    ;;
  ado)
    set +x
    echo "##vso[task.setvariable variable=objectIds;isOutput=true]${oids}"
    echo "##vso[task.setvariable variable=odataUris;isOutput=true]${odataUris}"
    ;;
  none)
    ;;
esac

# vim: set ts=2 sts=2 sw=2 et:
