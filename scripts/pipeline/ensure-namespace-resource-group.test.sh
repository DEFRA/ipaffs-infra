#!/usr/bin/env bash
#
# ensure-namespace-resource-group.test.sh
# Offline unit tests for ensure-namespace-resource-group.sh: fakes az (group
# show/create, aks get-credentials), kubectl (get namespace/resourcegroups/
# secrets) and kubelogin. No Azure, no cluster, no network.
# Usage: ./ensure-namespace-resource-group.test.sh

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/ensure-namespace-resource-group.sh"
work_dir="$(mktemp -d)"

cleanup_test_files() {
  if [[ "${KEEP_TEST_WORK_DIR:-false}" == "true" ]]; then
    echo "Test files retained at ${work_dir}"
  else
    rm -rf "${work_dir}"
  fi
}

trap cleanup_test_files EXIT

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

check_output_contains() {
  local name="$1"
  local expected="$2"

  check "${name}" "true" "$(grep -qF "${expected}" "${case_output}" && printf true || printf false)"
}

count_calls() {
  local pattern="$1"

  grep -cF -- "${pattern}" "${case_az_log}" 2>/dev/null || true
}

fake_bin="${work_dir}/bin"
mkdir -p "${fake_bin}"

cat > "${fake_bin}/az" <<'EOF'
#!/usr/bin/env bash

printf '%s\n' "$*" >> "${FAKE_AZ_LOG}"

if [[ "${1:-}" == "aks" && "${2:-}" == "install-cli" ]]; then
  exit 0
fi

if [[ "${1:-}" == "aks" && "${2:-}" == "get-credentials" ]]; then
  if [[ "${FAKE_AKS_SCENARIO:-success}" == "failure" ]]; then
    echo "AADSTS_ERROR: unable to get AKS credentials" >&2
    exit 1
  fi
  exit 0
fi

if [[ "${1:-}" == "group" && "${2:-}" == "show" ]]; then
  case "${FAKE_AZ_SCENARIO}" in
    not-found|create-failure)
      echo "ResourceGroupNotFound: Resource group 'devimpinfrg1401-pr-123' could not be found." >&2
      exit 3
      ;;
    owned-existing)
      printf '%s\n' '{"name":"devimpinfrg1401-pr-123","tags":{"ManagedBy":"ipaffs-manifest-pipeline","Namespace":"pr-123","BaseResourceGroup":"devimpinfrg1401"}}'
      exit 0
      ;;
    foreign-existing)
      printf '%s\n' '{"name":"devimpinfrg1401-pr-123","tags":{"Owner":"someone-else"}}'
      exit 0
      ;;
    no-tags-existing)
      printf '%s\n' '{"name":"devimpinfrg1401-pr-123"}'
      exit 0
      ;;
    show-failure)
      echo "Forbidden: cannot read resource group" >&2
      exit 1
      ;;
    unused)
      echo "Unexpected az group show call for unused scenario" >&2
      exit 99
      ;;
    *)
      echo "Unhandled scenario ${FAKE_AZ_SCENARIO} for group show" >&2
      exit 99
      ;;
  esac
fi

if [[ "${1:-}" == "group" && "${2:-}" == "create" ]]; then
  if [[ "${FAKE_AZ_SCENARIO}" == "create-failure" ]]; then
    echo "AuthorizationFailed: cannot create resource group" >&2
    exit 7
  fi
  exit 0
fi

echo "Unexpected az invocation: $*" >&2
exit 99
EOF

chmod +x "${fake_bin}/az"

cat > "${fake_bin}/kubelogin" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "${fake_bin}/kubelogin"

# A single FAKE_KUBECTL_SCENARIO drives all three kubectl call sites in the
# script (get namespace, get resourcegroups, get secrets), since each test
# case only needs one of them to matter.
cat > "${fake_bin}/kubectl" <<'EOF'
#!/usr/bin/env bash

scenario="${FAKE_KUBECTL_SCENARIO:-namespace-not-found}"

if [[ "${1:-}" == "get" && "${2:-}" == "namespace" ]]; then
  case "${scenario}" in
    namespace-not-found)
      exit 0
      ;;
    namespace-check-failure)
      echo "Unable to connect to the server: dial tcp: i/o timeout" >&2
      exit 1
      ;;
    *)
      echo "namespace/${3:-}"
      exit 0
      ;;
  esac
fi

if [[ "${1:-}" == "get" && "${2:-}" == "resourcegroups.resources.azure.com" ]]; then
  case "${scenario}" in
    namespace-exists-migrated)
      echo '{"items":[{"metadata":{"name":"devimpinfrg1401-pr-123"}}]}'
      exit 0
      ;;
    namespace-exists-base-only)
      echo '{"items":[{"metadata":{"name":"devimpinfrg1401"}}]}'
      exit 0
      ;;
    namespace-exists-fresh|namespace-exists-legacy-secret|secrets-list-failure)
      echo '{"items":[]}'
      exit 0
      ;;
    rg-list-failure)
      echo "Unable to connect to the server: dial tcp: i/o timeout" >&2
      exit 1
      ;;
    rg-list-malformed)
      echo 'not json'
      exit 0
      ;;
    *)
      echo "Unhandled FAKE_KUBECTL_SCENARIO ${scenario} for get resourcegroups" >&2
      exit 99
      ;;
  esac
fi

if [[ "${1:-}" == "get" && "${2:-}" == "secrets" ]]; then
  case "${scenario}" in
    namespace-exists-fresh)
      echo '{"items":[]}'
      exit 0
      ;;
    namespace-exists-legacy-secret)
      echo '{"items":[{"metadata":{"name":"sh.helm.release.v1.bootstrap.v1"}}]}'
      exit 0
      ;;
    secrets-list-failure)
      echo "Unable to connect to the server: dial tcp: i/o timeout" >&2
      exit 1
      ;;
    *)
      echo "Unhandled FAKE_KUBECTL_SCENARIO ${scenario} for get secrets" >&2
      exit 99
      ;;
  esac
fi

echo "Unexpected kubectl invocation: $*" >&2
exit 99
EOF

chmod +x "${fake_bin}/kubectl"

run_case() {
  local case_name="$1"
  local scenario="$2"
  local namespace="$3"
  local base_resource_group_name="${4:-devimpinfrg1401}"
  local kubectl_scenario="${5:-namespace-not-found}"
  local aks_scenario="${6:-success}"
  local default_namespace="${7:-dev}"
  local case_root="${work_dir}/${case_name}"

  mkdir -p "${case_root}"
  case_output="${case_root}/output.log"
  case_az_log="${case_root}/az.log"
  : > "${case_az_log}"

  (
    export PATH="${fake_bin}:${PATH}"
    export NAMESPACE="${namespace}"
    export DEFAULT_NAMESPACE="${default_namespace}"
    export BASE_RESOURCE_GROUP_NAME="${base_resource_group_name}"
    export SUBSCRIPTION_NAME="test-subscription"
    export LOCATION="uksouth"
    export AKS_NAME="test-aks"
    export FAKE_AZ_SCENARIO="${scenario}"
    export FAKE_AZ_LOG="${case_az_log}"
    export FAKE_KUBECTL_SCENARIO="${kubectl_scenario}"
    export FAKE_AKS_SCENARIO="${aks_scenario}"

    bash "${script_path}"
  ) > "${case_output}" 2>&1
  case_status=$?
}

run_case "default-namespace" unused dev
check "default namespace succeeds" "0" "${case_status}"
check "default namespace makes no az calls" "0" "$(wc -l < "${case_az_log}" | tr -d ' ')"
check_output_contains "default namespace reports the shared resource group" "namespace resource group: devimpinfrg1401"

run_case "reserved-namespace-mismatch" unused tst devimpinfrg1401 namespace-not-found success dev
check "a namespace reserved for another environment is refused" "1" "${case_status}"
check "a reserved namespace mismatch never calls az" "0" "$(wc -l < "${case_az_log}" | tr -d ' ')"
check_output_contains "a reserved namespace mismatch explains the refusal" "reserved for a different environment's default namespace"

run_case "alt-namespace-new" not-found pr-123 devimpinfrg1401 namespace-not-found
check "alternative namespace without an existing rg succeeds" "0" "${case_status}"
check "alternative namespace checks for an existing resource group" "1" "$(count_calls 'group show --name devimpinfrg1401-pr-123')"
check "alternative namespace creates the resource group" "1" "$(count_calls 'group create --name devimpinfrg1401-pr-123')"
check "alternative namespace tags the resource group with its ownership fingerprint" "1" "$(count_calls 'Namespace=pr-123')"
check_output_contains "alternative namespace reports its dedicated resource group" "namespace resource group: devimpinfrg1401-pr-123"

run_case "alt-namespace-create-failure" create-failure pr-123
check "resource group creation failure preserves its exit status" "7" "${case_status}"
check "resource group creation failure attempts creation once" "1" "$(count_calls 'group create')"
check "resource group creation failure publishes no deployment output" "0" "$(grep -cF '##vso[task.setvariable' "${case_output}" || true)"

run_case "alt-namespace-owned-existing" owned-existing pr-123 devimpinfrg1401 namespace-not-found
check "re-running for an owned existing resource group succeeds" "0" "${case_status}"
check "an owned existing resource group is reconciled idempotently" "1" "$(count_calls 'group create --name devimpinfrg1401-pr-123')"
check_output_contains "an owned existing resource group is recognised" "already exists and is owned by this pipeline"

run_case "alt-namespace-foreign-existing" foreign-existing pr-123 devimpinfrg1401 namespace-not-found
check "a foreign existing resource group is refused" "1" "${case_status}"
check "a foreign existing resource group is never created/updated" "0" "$(count_calls 'group create')"
check_output_contains "a foreign existing resource group explains the refusal" "Refusing to modify a resource group that may belong to something else"
check_output_contains "a foreign existing resource group documents recreation" "must be recreated, not migrated"

run_case "alt-namespace-no-tags-existing" no-tags-existing pr-123 devimpinfrg1401 namespace-not-found
check "an untagged pre-existing resource group is refused" "1" "${case_status}"
check "an untagged pre-existing resource group is never created/updated" "0" "$(count_calls 'group create')"
check_output_contains "an untagged pre-existing resource group explains the refusal" "is not tagged as owned by this pipeline"

run_case "alt-namespace-show-failure" show-failure pr-123 devimpinfrg1401 namespace-not-found
check "an az failure other than not-found is refused" "1" "${case_status}"
check "an az failure other than not-found never creates the resource group" "0" "$(count_calls 'group create')"
check_output_contains "an az failure other than not-found explains it could not determine existence" "Unable to determine whether resource group"

run_case "alt-namespace-fresh-existing-namespace" not-found pr-123 devimpinfrg1401 namespace-exists-fresh
check "a fresh, empty pre-existing namespace succeeds" "0" "${case_status}"
check "a fresh, empty pre-existing namespace creates the resource group" "1" "$(count_calls 'group create --name devimpinfrg1401-pr-123')"
check_output_contains "a fresh, empty pre-existing namespace is recognised as fresh" "treating as a fresh, empty namespace"

run_case "alt-namespace-idempotent-migrated" owned-existing pr-123 devimpinfrg1401 namespace-exists-migrated
check "an idempotent update for an already-migrated namespace succeeds" "0" "${case_status}"
check_output_contains "an idempotent update recognises the existing ASO ResourceGroup" "already has an ASO ResourceGroup"
check_output_contains "an idempotent update still reconciles the resource group" "already exists and is owned by this pipeline"

run_case "alt-namespace-legacy-base-only-cr" unused pr-123 devimpinfrg1401 namespace-exists-base-only
check "a legacy namespace with only the base ResourceGroup CR is refused" "1" "${case_status}"
check "a legacy base-only CR namespace never checks or creates the resource group" "0" "$(( $(count_calls 'group show') + $(count_calls 'group create') ))"
check_output_contains "a legacy base-only CR namespace explains the refusal" "existed before per-namespace resource groups were introduced"
check_output_contains "a legacy base-only CR namespace documents recreation" "must be recreated, not migrated"

run_case "alt-namespace-legacy-helm-secret" unused pr-123 devimpinfrg1401 namespace-exists-legacy-secret
check "a legacy namespace with a bootstrap release secret but no CR is refused" "1" "${case_status}"
check "a legacy helm-secret namespace never checks or creates the resource group" "0" "$(( $(count_calls 'group show') + $(count_calls 'group create') ))"
check_output_contains "a legacy helm-secret namespace explains the refusal" "existed before per-namespace resource groups were introduced"
check_output_contains "a legacy helm-secret namespace documents recreation" "must be recreated, not migrated"

run_case "alt-namespace-rg-list-failure" unused pr-123 devimpinfrg1401 rg-list-failure
check "an ASO ResourceGroup list failure fails closed" "1" "${case_status}"
check "an ASO ResourceGroup list failure never calls az group show/create" "0" "$(( $(count_calls 'group show') + $(count_calls 'group create') ))"
check_output_contains "an ASO ResourceGroup list failure explains it could not list resources" "Unable to list ASO ResourceGroup resources"

run_case "alt-namespace-rg-list-malformed" unused pr-123 devimpinfrg1401 rg-list-malformed
check "a malformed ASO ResourceGroup list fails closed" "1" "${case_status}"
check "a malformed ASO ResourceGroup list never calls az group show/create" "0" "$(( $(count_calls 'group show') + $(count_calls 'group create') ))"
check_output_contains "a malformed ASO ResourceGroup list explains the unexpected response" "returned an unexpected response"

run_case "alt-namespace-secrets-list-failure" unused pr-123 devimpinfrg1401 secrets-list-failure
check "a Helm release secret list failure fails closed" "1" "${case_status}"
check "a Helm release secret list failure never calls az group show/create" "0" "$(( $(count_calls 'group show') + $(count_calls 'group create') ))"
check_output_contains "a Helm release secret list failure explains it could not determine the deployment" "Unable to determine whether namespace"

run_case "alt-namespace-kubectl-namespace-check-failure" unused pr-123 devimpinfrg1401 namespace-check-failure
check "a kubectl namespace check failure fails closed" "1" "${case_status}"
check "a kubectl namespace check failure never calls az group show/create" "0" "$(( $(count_calls 'group show') + $(count_calls 'group create') ))"
check_output_contains "a kubectl namespace check failure explains it could not determine existence" "Unable to determine whether namespace"

run_case "alt-namespace-aks-auth-failure" unused pr-123 devimpinfrg1401 namespace-not-found failure
check "an AKS authentication failure fails closed" "1" "${case_status}"
check "an AKS authentication failure never checks or creates the resource group" "1" "$(count_calls 'aks get-credentials')"
check "an AKS authentication failure never calls az group show/create" "0" "$(( $(count_calls 'group show') + $(count_calls 'group create') ))"
check_output_contains "an AKS authentication failure explains the refusal" "Unable to authenticate against AKS cluster"

run_case "invalid-namespace-charset" unused "PR 123"
check "an invalid namespace fails safely" "1" "${case_status}"
check "an invalid namespace never calls az" "0" "$(wc -l < "${case_az_log}" | tr -d ' ')"
check_output_contains "an invalid namespace explains the charset requirement" "is invalid. Use lowercase alphanumeric and '-' only"

run_case "overlong-namespace" unused "$(printf 'a%.0s' {1..64})"
check "an overlong namespace fails safely" "1" "${case_status}"
check "an overlong namespace never calls az" "0" "$(wc -l < "${case_az_log}" | tr -d ' ')"
check_output_contains "an overlong namespace explains the 63 character limit" "exceeds 63 characters"

run_case "overlong-resource-group-name" unused "$(printf 'a%.0s' {1..63})" "$(printf 'b%.0s' {1..40})"
check "a namespace producing an overlong resource group name fails safely" "1" "${case_status}"
check "an overlong resource group name never calls az" "0" "$(wc -l < "${case_az_log}" | tr -d ' ')"
check_output_contains "an overlong resource group name explains the 90 character Azure limit" "exceeds the 90 character Azure limit"

if [[ "${failures}" -gt 0 ]]; then
  echo "${failures} test(s) failed"
  exit 1
fi

echo "all tests passed"
