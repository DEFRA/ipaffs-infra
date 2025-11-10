#!/bin/bash

set -ux

max_attempts=10
attempt=0

while (( attempt < max_attempts )); do
  RESULT="$(az ad group member add -g "${GROUP_ID}" --member-id "${PRINCIPAL_ID}" 2>&1)"
  STATUS=$?
  (( STATUS == 0 )) && exit 0
  [[ "${RESULT}" =~ "One or more added object references already exist" ]] && exit 0
  sleep 10
done

exit 1

# vim: set ts=2 sts=2 sw=2 et:
