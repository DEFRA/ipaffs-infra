#!/bin/bash

set -ux

TOKEN="$(az account get-access-token --scope https://graph.microsoft.com/.default --query accessToken -o tsv)"
[[ $? -ne 0 ]] && exit 1

max_attempts=30
successful=0
attempt=0
wait=2

while (( attempt < max_attempts )); do
  (( attempt++ ))

  result="$(curl -w '%{http_code}' -s -o /dev/null -H "Authorization: Bearer ${TOKEN}" "https://graph.microsoft.com/v1.0/groups/${GROUP_ID}/members/${PRINCIPAL_ID}/\$ref")"
  if [[ "${result}" == "200" ]]; then
    (( successful++ ))
    (( successful == 5 )) && exit 0
    wait=2
    sleep 5
  else
    successful=0
    sleep $wait
    (( wait*=2 ))
    (( wait > 60 )) && wait=60
  fi
done

exit 1

# vim: set ts=2 sts=2 sw=2 et:
