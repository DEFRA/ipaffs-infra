#!/usr/bin/env bash

## parse-playwright-results.sh
##
## Parse Playwright results.json file
##
## usage $0 [Playwright results file] [Link to Playwright report view] [K8s Environment] [Test Suite] [Test Filter]
## Required arguments
## [$1] - Playwright results file
## [$2] - Playwright report view URL
## [$3] - K8s Environment
## Optional arguments
## [$4] - Requested test suite (default: test)
## [$5] - Effective Playwright filter (overrides the requested suite)
set -euo pipefail

REPORT_FILE="${1:-results.json}"
DASHBOARD_URL="$2"
ENVIRONMENT="$3"
TEST_SUITE="${4:-test}"
TEST_FILTER="${5:- }"
OUTPUT_PAYLOAD="slack_payload.json"

# Match the runner: a nonblank filter always selects filtered functional tests.
if [[ -n "${TEST_FILTER// /}" ]]; then
    if [[ "$TEST_FILTER" == '@smoke' ]]; then
        SUITE_LABEL="Smoke tests (${TEST_FILTER})"
    else
        SUITE_LABEL="Filtered functional tests (${TEST_FILTER})"
    fi
else
    case "$TEST_SUITE" in
        test) SUITE_LABEL="Full functional suite" ;;
        test:a11y) SUITE_LABEL="Accessibility tests" ;;
        test:cross-browser) SUITE_LABEL="Cross-browser tests" ;;
        test:visual) SUITE_LABEL="Visual tests" ;;
        test:visual:update) SUITE_LABEL="Visual baseline update" ;;
        *) SUITE_LABEL="$TEST_SUITE" ;;
    esac
fi

# Encode filters as JSON and plain text so regex characters remain readable.
SUITE_SECTION=$(jq -cn --arg suite "$SUITE_LABEL" '{type: "section", text: {type: "plain_text", text: ("Test Suite : " + $suite)}}')

# Check if the report file exists
if [ ! -f "$REPORT_FILE" ]; then
    echo ":: Playwright report file '$REPORT_FILE' not found." >&2
    exit 1
fi

echo ":: Parsing Playwright JSON report: ${REPORT_FILE}."
TOTAL_SUITES=$(jq '.config.projects | length' "$REPORT_FILE" 2>/dev/null || echo "0")
TOTAL_SPECS=$(jq '[.suites[].specs[]?] | length' "$REPORT_FILE" 2>/dev/null || echo "0")
PASSED=$(jq '.stats.expected // 0' "$REPORT_FILE")
FAILED=$(jq '.stats.unexpected // 0' "$REPORT_FILE")
FLAKY=$(jq '.stats.flaky // 0' "$REPORT_FILE")
SKIPPED=$(jq '.stats.skipped // 0' "$REPORT_FILE")

TOTAL_TESTS=$((PASSED + FAILED + FLAKY + SKIPPED))

if [ "$FAILED" -gt 0 ]; then
    STATUS_TEXT="🔴- QA Test Suite Completed for ${ENVIRONMENT}"
    COLOR="#FF0000"
else
    STATUS_TEXT="🟢- QA Test Suite Completed for ${ENVIRONMENT}"
    COLOR="#36A64F"
fi

cat <<EOF > "$OUTPUT_PAYLOAD"
{
  "attachments": [
    {
      "color": "$COLOR",
      "blocks": [
        {
          "type": "header",
          "text": {
            "type": "plain_text",
            "text": "$STATUS_TEXT",
            "emoji": true
          }
        },
        $SUITE_SECTION,
        {
          "type": "section",
          "fields": [
            { "type": "mrkdwn", "text": "Environment : $ENVIRONMENT" },
            { "type": "mrkdwn", "text": "Total Tests : $TOTAL_TESTS" },
            { "type": "mrkdwn", "text": "Passed : $PASSED" },
            { "type": "mrkdwn", "text": "Failed : $FAILED" },
            { "type": "mrkdwn", "text": "Flaky : $FLAKY" },
            { "type": "mrkdwn", "text": "Skipped : $SKIPPED" }
          ]
        },
        {
          "type": "context",
          "elements": [
            {
              "type": "mrkdwn",
              "text": "Generated QA Automation CI | <${DASHBOARD_URL}|View Playwright Report> | $(date '+%Y-%m-%d %H:%M:%S %Z')"
            }
          ]
        }
      ]
    }
  ]
}
EOF

echo ":: Slack payload saved to '$OUTPUT_PAYLOAD'."
