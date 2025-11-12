#!/bin/bash

set -eux

echo Configuring git...
git config user.name "${GIT_USER}"
git config user.email "${GIT_EMAIL}"
git fetch origin
git checkout main

echo Updating chart version...
yq -i ".version = \"${NEW_VERSION}\"" "${CHART_PATH}/Chart.yaml"

echo Committing the change...
git add "${CHART_PATH}/Chart.yaml"
git diff --cached
git commit -m "[skip ci] build(deps): Bumping Chart version from \`${CURRENT_VERSION}\` to \`${NEW_VERSION}\`"
git push

# vim: set ts=2 sts=2 sw=2 et:
