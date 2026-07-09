#!/bin/bash
#
# Fan out the canonical Java Dependabot config to one or more service repos,
# pruning any block whose manifest/Dockerfile is absent. Writes each
# <repo>/.github/dependabot.yml. --template defaults to the java.yml next to
# this script.
#
# Usage:
#   sync-dependabot.sh [--template FILE] [--commit] REPO [REPO ...]
#
# REPO is the path to a checked-out service repo. The SyncDependabot pipeline
# stage runs this against the pipeline checkout:
#   sync-dependabot.sh "$(Pipeline.Workspace)/s/self"
#
# To preview locally, point it at a service checkout on disk:
#   sync-dependabot.sh /path/to/ipaffs-countries-microservice
#
# Write-only by default, leaving each working tree dirty for review. Pass
# --commit to also stage+commit in each repo (never pushes; refuses master/main).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template="${script_dir}/../../dependabot-templates/java.yml"
do_commit=false
repos=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --template) template="$2"; shift 2 ;;
    --commit)   do_commit=true; shift ;;
    -h|--help)  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)         echo "Unknown option: $1" >&2; exit 1 ;;
    *)          repos+=("$1"); shift ;;
  esac
done

command -v yq >/dev/null 2>&1 || { echo "yq is required but was not found on PATH" >&2; exit 1; }
[[ -f "${template}" ]] || { echo "Template not found: ${template}" >&2; exit 1; }
[[ ${#repos[@]} -gt 0 ]] || { echo "No target repos given (see --help)" >&2; exit 1; }

header_1="# AUTO-GENERATED from ipaffs-infra/dependabot-templates/java.yml — DO NOT EDIT HERE."
header_2="# Regenerate with ipaffs-infra/scripts/tools/sync-dependabot.sh after changing the template."

# Does the manifest required by update block <eco> at <dir> exist under <repo>?
manifest_present() {
  local repo="$1" eco="$2" dir="$3"
  local rel="${dir#/}"
  case "${eco}" in
    maven)  [[ -f "${repo}/${rel}/pom.xml" ]] ;;
    docker) compgen -G "${repo}/${rel}/Dockerfile*" >/dev/null ;;
    *)      return 0 ;;  # unknown ecosystem: keep it, let Dependabot decide
  esac
}

sync_repo() {
  local repo="$1"
  [[ -d "${repo}" ]] || { echo "  ! not a directory: ${repo}" >&2; return 1; }

  local out; out="$(mktemp)"
  cp "${template}" "${out}"

  local n; n="$(yq '.updates | length' "${out}")"
  local -a drop=()
  local i eco dir
  for (( i = 0; i < n; i++ )); do
    eco="$(yq ".updates[${i}].package-ecosystem" "${out}")"
    # Accept either `directory:` (singular) or the first of `directories:` (plural).
    dir="$(yq ".updates[${i}].directory // .updates[${i}].directories[0]" "${out}")"
    if [[ "${dir}" == "null" ]]; then
      echo "  ! updates[${i}] (${eco}) has no directory/directories — leaving it in" >&2
      continue
    fi
    if manifest_present "${repo}" "${eco}" "${dir}"; then
      echo "  keep  ${eco} ${dir}"
    else
      echo "  prune ${eco} ${dir} (no manifest)"
      drop+=("${i}")
    fi
  done

  # Delete high-to-low so earlier indices stay valid as entries are removed.
  local j
  for j in $(printf '%s\n' "${drop[@]:-}" | grep -E '^[0-9]+$' | sort -rn); do
    yq -i "del(.updates[${j}])" "${out}"
  done

  mkdir -p "${repo}/.github"
  local target="${repo}/.github/dependabot.yml"
  {
    printf '%s\n%s\n\n' "${header_1}" "${header_2}"
    cat "${out}"
  } > "${target}"
  rm -f "${out}"
  echo "  wrote ${target}"

  if [[ "${do_commit}" == true ]]; then
    local branch; branch="$(git -C "${repo}" rev-parse --abbrev-ref HEAD)"
    if [[ "${branch}" == "master" || "${branch}" == "main" ]]; then
      echo "  ! refusing to commit on ${branch}; create a feature branch first" >&2
      return 0
    fi
    git -C "${repo}" add .github/dependabot.yml
    if git -C "${repo}" diff --cached --quiet; then
      echo "  no changes to commit"
    else
      git -C "${repo}" commit -m "IMTA-21519: sync Dependabot config from ipaffs-infra template"
      echo "  committed on ${branch} (not pushed)"
    fi
  fi
}

failed=0
for repo in "${repos[@]}"; do
  echo "==> ${repo}"
  sync_repo "${repo}" || { failed=$((failed + 1)); echo "  ! skipped ${repo}" >&2; }
done

if [[ "${failed}" -gt 0 ]]; then
  echo "${failed} repo(s) failed" >&2
  exit 1
fi
