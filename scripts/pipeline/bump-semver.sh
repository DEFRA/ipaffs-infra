#!/bin/bash

set -eux

if [[ -z "${CURRENT_VERSION}" ]]; then
  echo "Must specify CURRENT_VERSION" >&2
  exit 1
fi

NEW_VERSION=

if [[ "${CURRENT_VERSION}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"
  minor=$((minor + 1))
  NEW_VERSION="${major}.${minor}.0"
else
  echo "Invalid version format: ${CURRENT_VERSION}" >&2
  exit 1
fi

echo "##vso[task.setvariable variable=newVersion;isOutput=true]${NEW_VERSION}"

# vim: set ts=2 sts=2 sw=2 et:
