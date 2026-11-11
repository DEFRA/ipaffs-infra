#!/bin/bash
# Copies npm packages into the DEFRA-EUTD-IPAFFS Azure Artifacts feed.
#
# For each name@version in PACKAGES_FILE, fetches the original tarball from the first
# source registry that has it (SOURCE_REGISTRIES, in order) and publishes it unchanged
# to FEED_REGISTRY, so the integrity hashes in existing lockfiles still match.
# Versions the feed already has are skipped.
#
# GITHUB_TOKEN is only used to read npm.pkg.github.com. DRY_RUN=true fetches and
# lists the uploads without making them.

set -euo pipefail

: "${PACKAGES_FILE:?}" "${FEED_REGISTRY:?}" "${SYSTEM_ACCESSTOKEN:?}"
DRY_RUN="${DRY_RUN:-true}"
SOURCE_REGISTRIES="${SOURCE_REGISTRIES:-https://artifactoryv2.azure.defra.cloud/artifactory/api/npm/npm-virtual-snapshots/ https://npm.pkg.github.com/}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

host_key() {
  local h="${1#https:}"
  echo "${h%/}/"
}

# Tokens only live in this temporary file for the length of the step.
{
  echo "$(host_key "${FEED_REGISTRY}"):_authToken=${SYSTEM_ACCESSTOKEN}"
  if [[ -n "${GITHUB_TOKEN:-}" && "${GITHUB_TOKEN}" != '$'\(* ]]; then
    echo "//npm.pkg.github.com/:_authToken=${GITHUB_TOKEN}"
  fi
} > "${work}/npmrc"
npm_() { npm --userconfig "${work}/npmrc" "$@"; }

published=0 skipped=0 failed=()
while IFS= read -r line; do
  line="${line%%#*}"
  line="$(echo "${line}" | xargs)"
  [[ -z "${line}" ]] && continue

  if npm_ view "${line}" version --registry "${FEED_REGISTRY}" >/dev/null 2>&1; then
    echo "in feed already: ${line}"
    skipped=$((skipped + 1))
    continue
  fi

  tarball="" from=""
  for registry in ${SOURCE_REGISTRIES}; do
    rm -rf "${work}/pack" && mkdir "${work}/pack"
    if (cd "${work}/pack" && npm_ pack "${line}" --registry "${registry}" --silent >/dev/null 2>&1); then
      tarball="$(ls "${work}/pack/"*.tgz)"
      from="${registry}"
      break
    fi
  done
  if [[ -z "${tarball}" ]]; then
    echo "##vso[task.logissue type=error]${line} not found in ${SOURCE_REGISTRIES}"
    failed+=("${line}")
    continue
  fi

  if [[ "${DRY_RUN}" == true ]]; then
    echo "would publish ${line} (from ${from}, sha512 $(openssl dgst -sha512 -binary "${tarball}" | base64 | head -c 16)...)"
    published=$((published + 1))
    continue
  fi

  # --registry takes precedence over a publishConfig.registry inside the tarball
  if npm_ publish "${tarball}" --registry "${FEED_REGISTRY}" --ignore-scripts; then
    echo "published ${line} (from ${from})"
    published=$((published + 1))
  else
    echo "##vso[task.logissue type=error]publish failed for ${line}"
    failed+=("${line}")
  fi
done < "${PACKAGES_FILE}"

echo "=== Summary"
echo "$([[ "${DRY_RUN}" == true ]] && echo 'to publish' || echo 'published'): ${published}, already in feed: ${skipped}"
echo "failed (${#failed[@]}): ${failed[*]:-none}"
(( ${#failed[@]} == 0 ))
