#!/usr/bin/env bash

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/update-manifest-service-values.sh"
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

write_source_values() {
  local service_root="$1"

  mkdir -p "${service_root}/deployment/dev" "${service_root}/config/dev"
  cat > "${service_root}/deployment/values.yaml" <<'EOF'
service: example-service
container:
  image: ipaffs/example-service:source-value-must-not-be-used
  replicas: 2
database:
  migrations:
    enabled: true
    image: ipaffs/example-service-configuration:source-value-must-not-be-used
config:
  FRESH_SETTING: fresh-value
EOF
  cat > "${service_root}/deployment/dev/values.yaml" <<'EOF'
config:
  ENVIRONMENT_SETTING: deployment-value
EOF
  cat > "${service_root}/config/values.yaml" <<'EOF'
service: legacy-config-service
config:
  FRESH_SETTING: legacy-config-value
EOF
  cat > "${service_root}/config/dev/values.yaml" <<'EOF'
config:
  ENVIRONMENT_SETTING: legacy-config-value
EOF
}

run_update() {
  local case_name="$1"
  local service_root="${work_dir}/${case_name}/service"
  local manifest_root="${work_dir}/${case_name}/manifest"

  write_source_values "${service_root}"
  mkdir -p "${manifest_root}/services/example-service"

  SERVICE_NAME=example-service \
    SERVICE_RUNTIME=java \
    BUILD_NUMBER=unused-build \
    MANIFEST_ROOT="${manifest_root}" \
    SERVICE_ROOT="${service_root}" \
    SKIP_CONTAINER_IMAGE_UPDATE=true \
    bash "${script_path}" >/dev/null
}

# A replacement removes stale source settings while preserving generated images.
case_name="both-images"
case_root="${work_dir}/${case_name}"
mkdir -p "${case_root}/manifest/services/example-service"
cat > "${case_root}/manifest/services/example-service/base.yaml" <<'EOF'
service: old-service
container:
  image: ipaffs/example-service:existing
  replicas: 99
database:
  migrations:
    enabled: false
    image: ipaffs/example-service-configuration:existing
env:
  - name: STALE_SETTING
    value: stale-value
staleRoot: remove-me
EOF
run_update "${case_name}"
base_file="${case_root}/manifest/services/example-service/base.yaml"

check "service values replace the existing base" \
  "example-service" "$(yq e -r '.service' "${base_file}")"
check "deployment values are used when a legacy config folder also exists" \
  "fresh-value" "$(yq e -r '.config.FRESH_SETTING' "${base_file}")"
check "source container values replace stale values" \
  "2" "$(yq e -r '.container.replicas' "${base_file}")"
check "a stale top-level env block is deleted" \
  "false" "$(yq e 'has("env")' "${base_file}")"
check "other stale keys are deleted" \
  "false" "$(yq e 'has("staleRoot")' "${base_file}")"
check "the existing container image is preserved" \
  "ipaffs/example-service:existing" "$(yq e -r '.container.image' "${base_file}")"
check "the existing migrations image is preserved" \
  "ipaffs/example-service-configuration:existing" \
  "$(yq e -r '.database.migrations.image' "${base_file}")"
env_file="${case_root}/manifest/environments/dev/example-service.yaml"
check "deployment environment values are used instead of legacy config values" \
  "deployment-value" "$(yq e -r '.config.ENVIRONMENT_SETTING' "${env_file}")"

# Neither image path is created when the existing manifest does not contain it.
case_name="no-images"
case_root="${work_dir}/${case_name}"
mkdir -p "${case_root}/manifest/services/example-service"
cat > "${case_root}/manifest/services/example-service/base.yaml" <<'EOF'
service: old-service
staleRoot: remove-me
EOF
run_update "${case_name}"
base_file="${case_root}/manifest/services/example-service/base.yaml"

check "a source container image is stripped when the existing image is absent" \
  "false" "$(yq e '.container | has("image")' "${base_file}")"
check "a source migrations image is stripped when the existing image is absent" \
  "false" "$(yq e '.database.migrations | has("image")' "${base_file}")"
check "replacement still deletes stale keys when images are absent" \
  "false" "$(yq e 'has("staleRoot")' "${base_file}")"

# Each image is optional and is preserved independently of the other one.
case_name="container-image-only"
case_root="${work_dir}/${case_name}"
mkdir -p "${case_root}/manifest/services/example-service"
cat > "${case_root}/manifest/services/example-service/base.yaml" <<'EOF'
container:
  image: ipaffs/example-service:container-only
EOF
run_update "${case_name}"
base_file="${case_root}/manifest/services/example-service/base.yaml"

check "a lone container image is preserved" \
  "ipaffs/example-service:container-only" "$(yq e -r '.container.image' "${base_file}")"
check "preserving a container image does not create a migrations image" \
  "false" "$(yq e '.database.migrations | has("image")' "${base_file}")"

case_name="migrations-image-only"
case_root="${work_dir}/${case_name}"
mkdir -p "${case_root}/manifest/services/example-service"
cat > "${case_root}/manifest/services/example-service/base.yaml" <<'EOF'
database:
  migrations:
    image: ipaffs/example-service-configuration:migrations-only
EOF
run_update "${case_name}"
base_file="${case_root}/manifest/services/example-service/base.yaml"

check "a lone migrations image is preserved" \
  "ipaffs/example-service-configuration:migrations-only" \
  "$(yq e -r '.database.migrations.image' "${base_file}")"
check "preserving a migrations image does not create a container image" \
  "false" "$(yq e '.container | has("image")' "${base_file}")"

# With no pre-existing base there is no generated image to preserve.
run_update "no-existing-base"
base_file="${work_dir}/no-existing-base/manifest/services/example-service/base.yaml"

check "a skipped build does not import a source container image into a new base" \
  "false" "$(yq e '.container | has("image")' "${base_file}")"
check "a skipped build does not import a source migrations image into a new base" \
  "false" "$(yq e '.database.migrations | has("image")' "${base_file}")"

# Environment files opt a service into deployment, including explicitly empty
# source values. Missing sources must not create entries in either build mode.
for skip_image_update in false true; do
  case_root="${work_dir}/environment-presence-${skip_image_update}"
  service_root="${case_root}/service"
  manifest_root="${case_root}/manifest"
  write_source_values "${service_root}"
  mkdir -p "${service_root}/deployment/tst" "${manifest_root}/environments/prd"
  printf '{}\n' > "${service_root}/deployment/tst/values.yaml"

  SERVICE_NAME=example-service \
    SERVICE_RUNTIME=java \
    BUILD_NUMBER=new-build \
    MANIFEST_ROOT="${manifest_root}" \
    SERVICE_ROOT="${service_root}" \
    SKIP_CONTAINER_IMAGE_UPDATE="${skip_image_update}" \
    bash "${script_path}" >/dev/null
  check "environment update succeeds with skip images=${skip_image_update}" "0" "$?"

  check "dev source values enable deployment with skip images=${skip_image_update}" \
    "deployment-value" \
    "$(yq e -r '.config.ENVIRONMENT_SETTING' "${manifest_root}/environments/dev/example-service.yaml")"
  check "explicitly empty tst source enables deployment with skip images=${skip_image_update}" \
    "true" "$(test -f "${manifest_root}/environments/tst/example-service.yaml" && printf true || printf false)"
  for environment in pre prd; do
    check "missing ${environment} source does not enable deployment with skip images=${skip_image_update}" \
      "false" "$(test -e "${manifest_root}/environments/${environment}/example-service.yaml" && printf true || printf false)"
  done
done

# A service with only the removed config folder is not treated as a values source.
case_name="config-only"
case_root="${work_dir}/${case_name}"
service_root="${case_root}/service"
manifest_root="${case_root}/manifest"
mkdir -p \
  "${service_root}/config/dev" \
  "${manifest_root}/services/example-service" \
  "${manifest_root}/environments/dev"
cat > "${service_root}/config/values.yaml" <<'EOF'
service: legacy-config-service
config:
  LEGACY_CONFIG_SETTING: must-not-be-imported
EOF
cat > "${service_root}/config/dev/values.yaml" <<'EOF'
config:
  LEGACY_ENVIRONMENT_SETTING: must-not-be-imported
EOF
cat > "${manifest_root}/services/example-service/base.yaml" <<'EOF'
service: existing-service
container:
  image: ipaffs/example-service:existing
EOF
cat > "${manifest_root}/environments/dev/example-service.yaml" <<'EOF'
config:
  EXISTING_ENVIRONMENT_SETTING: keep-me
EOF

update_output="$({
  SERVICE_NAME=example-service \
    SERVICE_RUNTIME=java \
    BUILD_NUMBER=unused-build \
    MANIFEST_ROOT="${manifest_root}" \
    SERVICE_ROOT="${service_root}" \
    SKIP_CONTAINER_IMAGE_UPDATE=true \
    bash "${script_path}"
} 2>&1)"
base_file="${manifest_root}/services/example-service/base.yaml"
env_file="${manifest_root}/environments/dev/example-service.yaml"

check "a config-only service reports that deployment values are missing" \
  "true" "$(printf '%s' "${update_output}" | grep -qF "No values.yaml found under ${service_root}/deployment" && printf true || printf false)"
check "a config-only base is not imported" \
  "existing-service" "$(yq e -r '.service' "${base_file}")"
check "a config-only setting is not imported" \
  "false" "$(yq e '.config | has("LEGACY_CONFIG_SETTING")' "${base_file}")"
check "a config-only environment is not imported" \
  "keep-me" "$(yq e -r '.config.EXISTING_ENVIRONMENT_SETTING' "${env_file}")"
check "a config-only environment setting is absent" \
  "false" "$(yq e '.config | has("LEGACY_ENVIRONMENT_SETTING")' "${env_file}")"

check "a missing deployment folder does not create other environment entries" \
  "false" "$(test -e "${manifest_root}/environments/pre/example-service.yaml" && printf true || printf false)"

# The pipeline is authoritative, including when source values specify another
# runtime. Both container build modes must retain their existing image behavior.
for runtime in java node; do
  for skip_image_update in false true; do
    case_root="${work_dir}/runtime-${runtime}-${skip_image_update}"
    service_root="${case_root}/service"
    manifest_root="${case_root}/manifest"
    write_source_values "${service_root}"
    mkdir -p "${manifest_root}/services/example-service"
    cat > "${manifest_root}/services/example-service/base.yaml" <<'EOF'
runtime: java
container:
  image: ipaffs/example-service:existing
database:
  migrations:
    image: ipaffs/example-service-configuration:existing
EOF
    source_runtime=java
    [[ "${runtime}" == "java" ]] && source_runtime=node
    SOURCE_RUNTIME="${source_runtime}" yq -i '.runtime = strenv(SOURCE_RUNTIME)' \
      "${service_root}/deployment/values.yaml"

    SERVICE_NAME=example-service \
      SERVICE_RUNTIME="${runtime}" \
      BUILD_NUMBER=new-build \
      MANIFEST_ROOT="${manifest_root}" \
      SERVICE_ROOT="${service_root}" \
      SKIP_CONTAINER_IMAGE_UPDATE="${skip_image_update}" \
      bash "${script_path}" >/dev/null
    check "${runtime} runtime update succeeds with skip images=${skip_image_update}" "0" "$?"
    base_file="${manifest_root}/services/example-service/base.yaml"
    check "pipeline ${runtime} overrides the source runtime with skip images=${skip_image_update}" \
      "${runtime}" "$(yq e -r '.runtime' "${base_file}")"
    expected_tag=new-build
    [[ "${skip_image_update}" == "true" ]] && expected_tag=existing
    check "${runtime} runtime preserves image behavior with skip images=${skip_image_update}" \
      "ipaffs/example-service:${expected_tag}" "$(yq e -r '.container.image' "${base_file}")"
    check "${runtime} runtime preserves migrations image behavior with skip images=${skip_image_update}" \
      "ipaffs/example-service-configuration:${expected_tag}" \
      "$(yq e -r '.database.migrations.image' "${base_file}")"
  done
done

# Runtime must come from the caller. Even valid source or existing metadata
# cannot rescue an unset, empty or invalid value, in either image mode.
for runtime_input in unset empty invalid; do
  for runtime_source in source existing; do
    for skip_image_update in false true; do
      case_name="${runtime_input}-runtime-${runtime_source}-${skip_image_update}"
      case_root="${work_dir}/${case_name}"
      service_root="${case_root}/service"
      manifest_root="${case_root}/manifest"
      write_source_values "${service_root}"
      mkdir -p "${manifest_root}"
      if [[ "${runtime_source}" == "source" ]]; then
        yq -i '.runtime = "node"' "${service_root}/deployment/values.yaml"
      else
        mkdir -p "${manifest_root}/services/example-service"
        printf 'runtime: java\n' > "${manifest_root}/services/example-service/base.yaml"
      fi
      cp -R "${manifest_root}" "${case_root}/manifest-before"
      runtime_env=(env -u SERVICE_RUNTIME)
      case "${runtime_input}" in
        empty) runtime_env+=(SERVICE_RUNTIME=) ;;
        invalid) runtime_env+=(SERVICE_RUNTIME=python) ;;
      esac
      SERVICE_NAME=example-service \
        BUILD_NUMBER=new-build \
        MANIFEST_ROOT="${manifest_root}" \
        SERVICE_ROOT="${service_root}" \
        SKIP_CONTAINER_IMAGE_UPDATE="${skip_image_update}" \
        "${runtime_env[@]}" bash "${script_path}" >/dev/null 2>&1
      check "${case_name} is rejected" "1" "$?"
      check "${case_name} leaves the manifest untouched" \
        "true" "$(diff -r "${case_root}/manifest-before" "${manifest_root}" >/dev/null && printf true || printf false)"
    done
  done
done

# FTR values are propagated as an optional configuration overlay in both modes.
for skip_image_update in false true; do
  case_root="${work_dir}/feature-overlay-${skip_image_update}"
  service_root="${case_root}/service"
  manifest_root="${case_root}/manifest"
  write_source_values "${service_root}"
  mkdir -p "${service_root}/deployment/ftr" "${manifest_root}"
  cat > "${service_root}/deployment/ftr/values.yaml" <<'EOF'
serviceBus:
  enabled: true
  useSecrets: true
externalSecret:
  secrets: []
EOF
  SERVICE_NAME=example-service \
    SERVICE_RUNTIME=java \
    BUILD_NUMBER=new-build \
    MANIFEST_ROOT="${manifest_root}" \
    SERVICE_ROOT="${service_root}" \
    SKIP_CONTAINER_IMAGE_UPDATE="${skip_image_update}" \
    bash "${script_path}" >/dev/null
  check "FTR values copy succeeds with skip images=${skip_image_update}" "0" "$?"
  feature_file="${manifest_root}/environments/ftr/example-service.yaml"
  check "FTR enables chart-managed Service Bus with skip images=${skip_image_update}" \
    "true" "$(yq e '.serviceBus.enabled' "${feature_file}")"
  check "FTR clears remote secret imports with skip images=${skip_image_update}" \
    "0" "$(yq e '.externalSecret.secrets | length' "${feature_file}")"
  check "FTR values carry the generated-file header with skip images=${skip_image_update}" \
    "# AUTO-GENERATED FILE. DO NOT EDIT DIRECTLY." "$(head -n 1 "${feature_file}")"
done

if [[ "${failures}" -gt 0 ]]; then
  echo "${failures} test(s) failed"
  exit 1
fi

echo "all tests passed"
