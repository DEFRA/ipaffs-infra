#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
infra_root="${work_dir}/infra"
manifest_root="${work_dir}/manifest"
mkdir -p "${infra_root}/helm-charts/bootstrap" "${infra_root}/scripts/pipeline" "${manifest_root}"
printf 'service: bootstrap\n' > "${infra_root}/helm-charts/bootstrap/values.yaml"
cp "${script_dir}/update-manifest-chart-version.sh" "${infra_root}/scripts/pipeline/"
cat > "${manifest_root}/helmfile.yaml.gotmpl" <<'EOF'
releases:
  - name: bootstrap
    chart: acr/helm/v1/repo/bootstrap
    version: 0.1.0
EOF

run_update() {
  CHART_VERSION=0.2.0 MANIFEST_ROOT="${manifest_root}" INFRA_ROOT="${infra_root}" \
    bash "${script_dir}/update-manifest-bootstrap-values.sh"
}

run_update
test ! -e "${manifest_root}/bootstrap/environments/ftr.yaml"
echo "ok - no FTR file is synthesized without a source overlay"
mkdir -p "${infra_root}/helm-charts/envs/ftr"
cat > "${infra_root}/helm-charts/envs/ftr/bootstrap-values.yaml" <<'EOF'
serviceBus:
  queues:
    - feature-queue
EOF
run_update
test "$(yq e -r '.serviceBus.queues[0]' "${manifest_root}/bootstrap/environments/ftr.yaml")" = feature-queue
test "$(head -n 1 "${manifest_root}/bootstrap/environments/ftr.yaml")" = '# AUTO-GENERATED FILE. DO NOT EDIT DIRECTLY.'
test "$(yq e -r '.releases[0].version' "${manifest_root}/helmfile.yaml.gotmpl")" = 0.2.0
echo "ok - FTR bootstrap values are copied and version publication is preserved"
