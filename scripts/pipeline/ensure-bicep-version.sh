#!/usr/bin/env bash
# @onlyIfNotExists requires Bicep >= 0.38.3. Use one verified compiler for
# ownership-sensitive NSG templates in deployment jobs and their previews.
set -euo pipefail

required_bicep_version=0.43.8

installed_bicep_version() {
  az bicep version --only-show-errors 2>/dev/null |
    sed -nE 's/^Bicep CLI version ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p'
}

current_bicep_version="$(installed_bicep_version)" || current_bicep_version=''
if [[ "$current_bicep_version" != "$required_bicep_version" ]]; then
  az bicep install --version "v${required_bicep_version}" --only-show-errors > /dev/null
fi

if [[ "$(installed_bicep_version)" != "$required_bicep_version" ]]; then
  echo 'The required Bicep compiler is unavailable; refusing to compile deployment templates.' >&2
  exit 1
fi
