#!/usr/bin/env bash

set -euo pipefail

: "${BUILD_NUMBER:?BUILD_NUMBER is required}"
: "${MANIFEST_ROOT:?MANIFEST_ROOT is required}"
: "${SERVICE_NAME:?SERVICE_NAME is required}"
: "${SOURCE_REPOSITORY_ROOT:?SOURCE_REPOSITORY_ROOT is required}"
: "${SOURCE_REPOSITORY_URI:?SOURCE_REPOSITORY_URI is required}"
: "${SOURCE_VERSION:?SOURCE_VERSION is required}"

if ! git -C "${SOURCE_REPOSITORY_ROOT}" cat-file -e "${SOURCE_VERSION}^{commit}" >/dev/null 2>&1; then
  echo "Source commit '${SOURCE_VERSION}' is not available in ${SOURCE_REPOSITORY_ROOT}" >&2
  exit 1
fi

source_sha="$(git -C "${SOURCE_REPOSITORY_ROOT}" rev-parse "${SOURCE_VERSION}^{commit}")"
source_subject="$(git -C "${SOURCE_REPOSITORY_ROOT}" show -s --format=%s "${source_sha}")"
source_message="$(git -C "${SOURCE_REPOSITORY_ROOT}" show -s --format=%B "${source_sha}")"

source_title="${source_subject}"
pull_request_number=""

# GitHub merge commits use a generic subject and put the PR title in the first
# non-empty line of the body.
if [[ "${source_subject}" =~ ^Merge[[:space:]]pull[[:space:]]request[[:space:]]\#([0-9]+)([[:space:]]|$) ]]; then
  pull_request_number="${BASH_REMATCH[1]}"
  pull_request_title="$(printf '%s\n' "${source_message}" | awk 'NR == 1 { next } NF { print; exit }')"
  if [[ -n "${pull_request_title}" ]]; then
    source_title="${pull_request_title}"
  fi
# GitHub's default squash-merge subject ends with the PR number.
elif [[ "${source_subject}" =~ \(\#([0-9]+)\)$ ]]; then
  pull_request_number="${BASH_REMATCH[1]}"
fi

if [[ -n "${pull_request_number}" && ! "${source_title}" =~ \(\#${pull_request_number}\)$ ]]; then
  source_title="${source_title} (#${pull_request_number})"
fi

repository_url="${SOURCE_REPOSITORY_URI%/}"
repository_url="${repository_url%.git}"

# Build.Repository.Uri is normally HTTPS for GitHub repositories, but also
# accept the common SSH forms so locally queued or migrated pipelines retain
# clickable provenance links.
case "${repository_url}" in
  git@github.com:*)
    repository_url="https://github.com/${repository_url#git@github.com:}"
    ;;
  ssh://git@github.com/*)
    repository_url="https://github.com/${repository_url#ssh://git@github.com/}"
    ;;
esac

commit_message_file="$(mktemp)"
trap 'rm -f "${commit_message_file}"' EXIT

{
  printf '%s: %s\n\n' "${SERVICE_NAME}" "${source_title}"
  printf 'Automated manifest update for build %s.\n\n' "${BUILD_NUMBER}"
  if [[ -n "${pull_request_number}" ]]; then
    printf 'Origin-PR: %s/pull/%s\n' "${repository_url}" "${pull_request_number}"
  fi
  printf 'Origin-Commit: %s/commit/%s\n' "${repository_url}" "${source_sha}"
  printf 'Build: %s\n' "${BUILD_NUMBER}"
} >"${commit_message_file}"

git -C "${MANIFEST_ROOT}" commit --file="${commit_message_file}"
