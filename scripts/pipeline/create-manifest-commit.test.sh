#!/usr/bin/env bash

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/create-manifest-commit.sh"
work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

failures=0

check() {
  local name="$1"
  local expected="$2"
  local actual="$3"

  if [[ "${actual}" == "${expected}" ]]; then
    echo "ok   - ${name}"
  else
    echo "FAIL - ${name}: expected '${expected}' but got '${actual}'"
    failures=$((failures + 1))
  fi
}

init_repo() {
  local repository_root="$1"

  git init -q -b main "${repository_root}"
  git -C "${repository_root}" config user.name "Test User"
  git -C "${repository_root}" config user.email "test@example.com"
  printf 'initial\n' >"${repository_root}/tracked.txt"
  git -C "${repository_root}" add tracked.txt
  git -C "${repository_root}" commit -qm "Initial commit"
}

create_source_commit() {
  local source_root="$1"
  local subject="$2"

  printf 'change\n' >>"${source_root}/tracked.txt"
  git -C "${source_root}" add tracked.txt
  git -C "${source_root}" commit -qm "${subject}"
}

run_manifest_commit() {
  local case_name="$1"
  local repository_uri="$2"
  local source_root="${work_dir}/${case_name}/source"
  local manifest_root="${work_dir}/${case_name}/manifest"
  local source_version

  source_version="$(git -C "${source_root}" rev-parse HEAD)"
  init_repo "${manifest_root}"
  printf 'updated\n' >>"${manifest_root}/tracked.txt"
  git -C "${manifest_root}" add tracked.txt

  BUILD_NUMBER=20260907.12 \
    MANIFEST_ROOT="${manifest_root}" \
    SERVICE_NAME=example-service \
    SOURCE_REPOSITORY_ROOT="${source_root}" \
    SOURCE_REPOSITORY_URI="${repository_uri}" \
    SOURCE_VERSION="${source_version}" \
    bash "${script_path}" >/dev/null
}

# A direct commit mirrors its subject and links back to the source commit.
case_name="direct-commit"
case_root="${work_dir}/${case_name}"
init_repo "${case_root}/source"
create_source_commit "${case_root}/source" "IMTA-100: Improve validation"
source_sha="$(git -C "${case_root}/source" rev-parse HEAD)"
run_manifest_commit "${case_name}" "https://github.com/DEFRA/example-service.git"
manifest_message="$(git -C "${case_root}/manifest" log -1 --format=%B)"

check "a direct commit mirrors the source title" \
  "example-service: IMTA-100: Improve validation" \
  "$(git -C "${case_root}/manifest" log -1 --format=%s)"
check "a direct commit links to its origin commit" \
  "true" \
  "$(printf '%s' "${manifest_message}" | grep -qF "Origin-Commit: https://github.com/DEFRA/example-service/commit/${source_sha}" && printf true || printf false)"
check "a direct commit does not invent a PR link" \
  "false" \
  "$(printf '%s' "${manifest_message}" | grep -qF 'Origin-PR:' && printf true || printf false)"

# A GitHub merge commit takes the real PR title from its body.
case_name="merge-commit"
case_root="${work_dir}/${case_name}"
init_repo "${case_root}/source"
git -C "${case_root}/source" checkout -qb feature/test
create_source_commit "${case_root}/source" "Implementation detail"
git -C "${case_root}/source" checkout -q main
git -C "${case_root}/source" merge -q --no-ff feature/test \
  -m "Merge pull request #45 from DEFRA/feature/test" \
  -m "IMTA-21617: convert deployment env to config"
run_manifest_commit "${case_name}" "git@github.com:DEFRA/example-service.git"
manifest_message="$(git -C "${case_root}/manifest" log -1 --format=%B)"

check "a merge commit uses the PR title and number" \
  "example-service: IMTA-21617: convert deployment env to config (#45)" \
  "$(git -C "${case_root}/manifest" log -1 --format=%s)"
check "a merge commit links to its origin PR" \
  "true" \
  "$(printf '%s' "${manifest_message}" | grep -qF 'Origin-PR: https://github.com/DEFRA/example-service/pull/45' && printf true || printf false)"

# A squash merge keeps the existing PR suffix without duplicating it.
case_name="squash-commit"
case_root="${work_dir}/${case_name}"
init_repo "${case_root}/source"
create_source_commit "${case_root}/source" "Reduce JDK MaxRAMPercentage to 60 (#39)"
run_manifest_commit "${case_name}" "ssh://git@github.com/DEFRA/example-service.git"
manifest_message="$(git -C "${case_root}/manifest" log -1 --format=%B)"

check "a squash commit preserves its title and PR suffix" \
  "example-service: Reduce JDK MaxRAMPercentage to 60 (#39)" \
  "$(git -C "${case_root}/manifest" log -1 --format=%s)"
check "a squash commit links to its origin PR" \
  "true" \
  "$(printf '%s' "${manifest_message}" | grep -qF 'Origin-PR: https://github.com/DEFRA/example-service/pull/39' && printf true || printf false)"
check "the manifest commit records the build number" \
  "true" \
  "$(printf '%s' "${manifest_message}" | grep -qF 'Build: 20260907.12' && printf true || printf false)"

if [[ "${failures}" -gt 0 ]]; then
  echo "${failures} test(s) failed"
  exit 1
fi

echo "all tests passed"
