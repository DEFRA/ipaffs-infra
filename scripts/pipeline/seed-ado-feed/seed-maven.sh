#!/bin/bash
# Copies internal Maven artifacts into the DEFRA-EUTD-IPAFFS Azure Artifacts feed.
#
# 1. Resolves every line of ARTIFACTS_FILE (transitively) with SOURCE_SETTINGS, the
#    existing CI settings that read Artifactory and GitHub Packages, into an empty
#    local repository.
# 2. Uploads every artifact that came from a non-public repository (anything except
#    PUBLIC_REPO_IDS) to FEED_URL with SYSTEM_ACCESSTOKEN, skipping versions the feed
#    already has. Feed versions are immutable, so the script is safe to re-run.
#
# DRY_RUN=true resolves and lists the uploads without making them.

set -euo pipefail

: "${ARTIFACTS_FILE:?}" "${SOURCE_SETTINGS:?}" "${FEED_URL:?}" "${SYSTEM_ACCESSTOKEN:?}"
DRY_RUN="${DRY_RUN:-true}"
PUBLIC_REPO_IDS="${PUBLIC_REPO_IDS:-central jitpack.io}"
DEPENDENCY_PLUGIN=org.apache.maven.plugins:maven-dependency-plugin:3.8.1
DEPLOY_PLUGIN=org.apache.maven.plugins:maven-deploy-plugin:3.1.3

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
source_repo="${work}/source"
deploy_repo="${work}/deploy"
FEED_URL="${FEED_URL%/}"

# Only the feed's server entry; the token is read from the environment by Maven, so
# it is never written to disk. The feed mirrors Maven Central for the deploy plugin.
cat > "${work}/deploy-settings.xml" <<EOF
<settings>
  <servers>
    <server>
      <id>ipaffs-feed</id>
      <username>build</username>
      <password>\${env.SYSTEM_ACCESSTOKEN}</password>
    </server>
  </servers>
  <mirrors>
    <mirror>
      <id>ipaffs-feed</id>
      <mirrorOf>*</mirrorOf>
      <url>${FEED_URL}</url>
    </mirror>
  </mirrors>
</settings>
EOF

echo "=== Resolving"
failed=()
while IFS= read -r line; do
  line="${line%%#*}"
  line="$(echo "${line}" | xargs)"
  [[ -z "${line}" ]] && continue
  if mvn -B -ntp -q -s "${SOURCE_SETTINGS}" -Dmaven.repo.local="${source_repo}" \
      "${DEPENDENCY_PLUGIN}:get" -Dartifact="${line}" -Dtransitive=true >"${work}/get.log" 2>&1; then
    echo "resolved ${line}"
  else
    echo "##vso[task.logissue type=warning]could not resolve ${line}"
    grep -E '\[ERROR\]' "${work}/get.log" | head -3 || true
    failed+=("${line}")
  fi
done < "${ARTIFACTS_FILE}"

echo "=== Uploading"
is_public() {
  local id
  for id in ${PUBLIC_REPO_IDS}; do [[ "$1" == "${id}" ]] && return 0; done
  return 1
}

uploaded=0 skipped=0 upload_failed=()
# _remote.repositories records which repository id each file was downloaded from.
while IFS= read -r marker; do
  dir="$(dirname "${marker}")"
  version="$(basename "${dir}")"
  artifact_id="$(basename "$(dirname "${dir}")")"
  pom="${dir}/${artifact_id}-${version}.pom"
  [[ -f "${pom}" ]] || continue
  [[ "${version}" == *-SNAPSHOT ]] && continue

  source_id="$(sed -n "s/^${artifact_id}-${version}\.pom>\(.*\)=$/\1/p" "${marker}" | head -1)"
  if [[ -z "${source_id}" ]] || is_public "${source_id}"; then
    continue
  fi

  rel="${dir#"${source_repo}/"}"
  coords="${rel%/*/*}"
  coords="${coords//\//.}:${artifact_id}:${version}"

  status="$(curl -s -o /dev/null -w '%{http_code}' -u "build:${SYSTEM_ACCESSTOKEN}" \
    "${FEED_URL}/${rel}/${artifact_id}-${version}.pom")"
  if [[ "${status}" == 200 ]]; then
    echo "in feed already: ${coords}"
    skipped=$((skipped + 1))
    continue
  fi

  args=(-DpomFile="${pom}" -DgeneratePom=false -DrepositoryId=ipaffs-feed -Durl="${FEED_URL}")
  main="${dir}/${artifact_id}-${version}.jar"
  if [[ -f "${main}" ]]; then
    args+=(-Dfile="${main}")
  else
    args+=(-Dfile="${pom}" -Dpackaging=pom)
  fi

  # attached jars such as -tests or -sources
  files=() classifiers=() types=()
  for extra in "${dir}/${artifact_id}-${version}"-*.jar; do
    [[ -f "${extra}" ]] || continue
    classifier="${extra##*/${artifact_id}-${version}-}"
    files+=("${extra}"); classifiers+=("${classifier%.jar}"); types+=(jar)
  done
  if (( ${#files[@]} > 0 )); then
    args+=(-Dfiles="$(IFS=,; echo "${files[*]}")" -Dclassifiers="$(IFS=,; echo "${classifiers[*]}")" -Dtypes="$(IFS=,; echo "${types[*]}")")
  fi

  if [[ "${DRY_RUN}" == true ]]; then
    echo "would upload ${coords} (from ${source_id}${classifiers:+, with ${classifiers[*]}})"
    uploaded=$((uploaded + 1))
    continue
  fi

  if mvn -B -ntp -q -s "${work}/deploy-settings.xml" -Dmaven.repo.local="${deploy_repo}" \
      "${DEPLOY_PLUGIN}:deploy-file" "${args[@]}" >"${work}/deploy.log" 2>&1; then
    echo "uploaded ${coords} (from ${source_id})"
    uploaded=$((uploaded + 1))
  else
    echo "##vso[task.logissue type=error]upload failed for ${coords}"
    grep -E '\[ERROR\]' "${work}/deploy.log" | head -5 || true
    upload_failed+=("${coords}")
  fi
done < <(find "${source_repo}" -name _remote.repositories | sort)

echo "=== Summary"
echo "$([[ "${DRY_RUN}" == true ]] && echo 'to upload' || echo 'uploaded'): ${uploaded}, already in feed: ${skipped}"
echo "unresolved (${#failed[@]}): ${failed[*]:-none}"
echo "failed uploads (${#upload_failed[@]}): ${upload_failed[*]:-none}"
(( ${#upload_failed[@]} == 0 ))
