#!/usr/bin/env bash

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/add-entra-group-members.sh"
work_dir="$(mktemp -d)"

# Invoked by the EXIT trap below.
# shellcheck disable=SC2329
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

  check "${name}" \
    "true" \
    "$(grep -qF "${expected}" "${case_output}" && printf true || printf false)"
}

count_requests() {
  local request_type="$1"

  grep -cx "${request_type}" "${case_curl_log}" 2>/dev/null || true
}

fake_bin="${work_dir}/bin"
mkdir -p "${fake_bin}"

cat > "${fake_bin}/az" <<'EOF'
#!/usr/bin/env bash

printf '%s\n' "$*" >> "${FAKE_AZ_LOG}"

if [[ "$*" == "account get-access-token --scope https://graph.microsoft.com/.default --query accessToken -o tsv" ]]; then
  printf 'fake-token\n'
  exit 0
fi

echo "Unexpected az invocation: $*" >&2
exit 1
EOF

cat > "${fake_bin}/curl" <<'EOF'
#!/usr/bin/env bash

method=""
request_data=""
output_file=""
url=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -X)
      shift
      method="$1"
      ;;
    -d)
      shift
      request_data="$1"
      ;;
    -o)
      shift
      output_file="$1"
      ;;
    -H | -w)
      shift
      ;;
    -sS)
      ;;
    *)
      url="$1"
      ;;
  esac
  shift
done

if [[ "${url}" == "https://graph.microsoft.com/v1.0/\$batch" ]]; then
  printf 'BATCH\n' >> "${FAKE_CURL_LOG}"
  printf '%s' "${request_data}" > "${FAKE_BATCH_REQUEST}"
  batch_count="$(cat "${FAKE_BATCH_STATE}")"
  batch_count=$((batch_count + 1))
  printf '%s\n' "${batch_count}" > "${FAKE_BATCH_STATE}"

  if [[ "${batch_count}" -eq 2 && -n "${FAKE_BATCH_SECOND_RESPONSE:-}" ]]; then
    printf '%s' "${FAKE_BATCH_SECOND_RESPONSE}"
  else
    printf '%s' "${FAKE_BATCH_RESPONSE}"
  fi
  exit "${FAKE_BATCH_EXIT:-0}"
fi

if [[ "${method}" == "PATCH" ]]; then
  printf 'PATCH\n' >> "${FAKE_CURL_LOG}"
  jq -c . <<<"${request_data}" >> "${FAKE_PATCH_REQUEST}"
  printf '%s' "${FAKE_PATCH_RESPONSE:-}" > "${output_file}"
  printf '%s' "${FAKE_PATCH_STATUS:-204}"
  exit 0
fi

echo "Unexpected curl invocation: ${method} ${url}" >&2
exit 1
EOF

chmod +x "${fake_bin}/az" "${fake_bin}/curl"

run_case() {
  local case_name="$1"
  local batch_response="$2"
  local group_members="$3"
  local batch_exit="${4:-0}"
  local batch_second_response="${5:-}"
  local case_root="${work_dir}/${case_name}"

  mkdir -p "${case_root}"

  case_output="${case_root}/output.log"
  case_az_log="${case_root}/az.log"
  case_curl_log="${case_root}/curl.log"
  case_batch_state="${case_root}/batch-state"
  case_batch_request="${case_root}/batch-request.json"
  case_patch_request="${case_root}/patch-request.json"
  : > "${case_az_log}"
  : > "${case_curl_log}"
  printf '0\n' > "${case_batch_state}"
  : > "${case_batch_request}"
  : > "${case_patch_request}"

  if PATH="${fake_bin}:${PATH}" \
    GROUP_ID=test-group \
    GROUP_MEMBERS="${group_members}" \
    CHECK_EXISTING_MEMBERS=true \
    FAKE_AZ_LOG="${case_az_log}" \
    FAKE_CURL_LOG="${case_curl_log}" \
    FAKE_BATCH_STATE="${case_batch_state}" \
    FAKE_BATCH_REQUEST="${case_batch_request}" \
    FAKE_PATCH_REQUEST="${case_patch_request}" \
    FAKE_BATCH_RESPONSE="${batch_response}" \
    FAKE_BATCH_SECOND_RESPONSE="${batch_second_response}" \
    FAKE_BATCH_EXIT="${batch_exit}" \
    FAKE_PATCH_STATUS=204 \
    bash "${script_path}" > "${case_output}" 2>&1; then
    case_status=0
  else
    case_status=$?
  fi
}

all_existing_response='{
  "responses": [
    {"id":"0","status":200},
    {"id":"1","status":200}
  ]
}'

run_case "all-existing" "${all_existing_response}" "member-a member-b member-a"
check "all-existing succeeds" "0" "${case_status}"
check "all-existing performs one membership batch" "1" "$(count_requests BATCH)"
check "all-existing performs no group update" "0" "$(count_requests PATCH)"
check_output_contains "all-existing reports the no-op" "All requested members are already present"

one_new_response='{
  "responses": [
    {"id":"1","status":404},
    {"id":"0","status":200}
  ]
}'

run_case "one-new" "${one_new_response}" "member-a member-b"
check "one-new succeeds" "0" "${case_status}"
check "one-new performs one membership batch" "1" "$(count_requests BATCH)"
check "one-new performs one group update" "1" "$(count_requests PATCH)"
check_output_contains "one-new accepts out-of-order batch responses" "Successfully added 1 requested members"
check "one-new adds only the missing member" \
  "https://graph.microsoft.com/v1.0/directoryObjects/member-b" \
  "$(jq -r '."members@odata.bind" | join(" ")' "${case_patch_request}")"

denied_response='{
  "responses": [
    {"id":"0","status":403,"body":{"error":{"code":"Authorization_RequestDenied"}}},
    {"id":"1","status":403,"body":{"error":{"code":"Authorization_RequestDenied"}}}
  ]
}'

run_case "lookup-denied" "${denied_response}" "member-a member-b"
check "lookup-denied preserves the existing successful path" "0" "${case_status}"
check "lookup-denied attempts one membership batch" "1" "$(count_requests BATCH)"
check "lookup-denied performs one group update" "1" "$(count_requests PATCH)"
check "lookup-denied sends every requested member to the existing add path" \
  "member-a member-b" \
  "$(jq -r '."members@odata.bind"[] | split("/")[-1]' "${case_patch_request}" | paste -sd ' ' -)"
check_output_contains "lookup-denied explains the fallback" "continuing with the existing add path"

incomplete_response='{
  "responses": [
    {"id":"0","status":200}
  ]
}'

run_case "incomplete-response" "${incomplete_response}" "member-a member-b"
check "an incomplete lookup response preserves the existing successful path" "0" "${case_status}"
check "an incomplete lookup response sends every requested member to the existing add path" \
  "member-a member-b" \
  "$(jq -r '."members@odata.bind"[] | split("/")[-1]' "${case_patch_request}" | paste -sd ' ' -)"

first_chunk_existing_response="$(jq -n '{responses: [range(0; 20) | {id: (. | tostring), status: 200}]}')"
many_members="$(printf 'member-%02d ' {0..20})"
run_case "later-chunk-failure" "${first_chunk_existing_response}" "${many_members}" 0 '{"responses":[]}'
check "a later lookup failure preserves the existing successful path" "0" "${case_status}"
check "a later lookup failure attempts both membership batches" "2" "$(count_requests BATCH)"
check "a later lookup failure preserves 20-member update chunks" "2" "$(count_requests PATCH)"
check "a later lookup failure sends all original members to the existing add path" \
  "${many_members% }" \
  "$(jq -sr '[.[] | ."members@odata.bind"[] | split("/")[-1]] | join(" ")' "${case_patch_request}")"

run_case "lookup-request-failure" "" "member-a member-b" 22
check "a lookup request failure preserves the existing successful path" "0" "${case_status}"
check "a lookup request failure performs one group update" "1" "$(count_requests PATCH)"
check_output_contains "a lookup request failure explains the fallback" "Membership lookup batch request failed"

if [[ "${failures}" -gt 0 ]]; then
  echo "${failures} test(s) failed"
  exit 1
fi

echo "all tests passed"
