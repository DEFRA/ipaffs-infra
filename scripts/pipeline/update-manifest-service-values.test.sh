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

  mkdir -p "${service_root}/deployment"
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
}

run_update() {
  local case_name="$1"
  local service_root="${work_dir}/${case_name}/service"
  local manifest_root="${work_dir}/${case_name}/manifest"

  write_source_values "${service_root}"
  mkdir -p "${manifest_root}/services/example-service"

  SERVICE_NAME=example-service \
    BUILD_NUMBER=unused-build \
    MANIFEST_ROOT="${manifest_root}" \
    SERVICE_ROOT="${service_root}" \
    SKIP_CONTAINER_IMAGE_UPDATE=true \
    bash "${script_path}" >/dev/null
}

# A replacement removes every key that is not in the service source, while the
# two generated image fields survive unchanged.
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

if [[ "${failures}" -gt 0 ]]; then
  echo "${failures} test(s) failed"
  exit 1
fi

echo "all tests passed"
