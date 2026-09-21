#!/usr/bin/env bash

## parse-playwright-results.sh
##
## Parse Playwright results.json file
##
## usage $0 [Playwright results file] [Link to Playwright report view]
## Required arguments
## [$1] - Playwright results file
## [$2] - Playwright report view URL
## [$3] - K8s Environment
set -euo pipefail

REPORT_FILE="${1:-results.json}"
DASHBOARD_URL="$2"
ENVIRONMENT="$3"
OUTPUT_PAYLOAD="slack_payload.json"

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
