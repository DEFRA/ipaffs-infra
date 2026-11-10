#!/usr/bin/env bash
# Use the same Azure CLI-managed Bicep compiler in CI, What-If and deployments.
set -euo pipefail

required_bicep_version=0.49.2
export AZURE_BICEP_USE_BINARY_FROM_PATH=false

installed_bicep_version() {
  az bicep version --only-show-errors 2>/dev/null |
    sed -nE 's/^Bicep CLI version ([0-9]+\.[0-9]+\.[0-9]+)([[:space:]].*)?$/\1/p'
}

current_bicep_version="$(installed_bicep_version)" || current_bicep_version=''
if [[ "$current_bicep_version" != "$required_bicep_version" ]]; then
  az bicep install --version "v${required_bicep_version}" --only-show-errors > /dev/null
  current_bicep_version="$(installed_bicep_version)" || current_bicep_version=''
fi

if [[ "$current_bicep_version" != "$required_bicep_version" ]]; then
  echo "Bicep $required_bicep_version is required, found ${current_bicep_version:-no compiler}; refusing to compile deployment templates." >&2
  exit 1
fi

echo "Verified Bicep CLI version $current_bicep_version"
