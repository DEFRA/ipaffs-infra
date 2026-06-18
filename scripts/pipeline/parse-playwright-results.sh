#!/usr/bin/env bash

set -euo pipefail

REPORT_FILE="${1:-results.json}"
DASHBOARD_URL="$2"
OUTPUT_PAYLOAD="slack_payload.json"

# Check if the report file exists
if [ ! -f "$REPORT_FILE" ]; then
    echo ":: Playwright report file '$REPORT_FILE' not found." >&2
    exit 1
fi

echo ":: Parsing Playwright JSON report: ${REPORT_FILE}."
TOTAL_SUITES=$(jq '.config.projects | length' "$REPORT_FILE" 2>/dev/null || echo "0")
TOTAL_SPECS=$(jq '[.suites[].specs[]?] | length' "$REPORT_FILE" 2>/dev/null || echo "0")
PASSED=$(jq '[.. | objects | select(has("status")) | select(.status == "expected")] | length' "$REPORT_FILE")
FAILED=$(jq '[.. | objects | select(has("status")) | select(.status == "unexpected")] | length' "$REPORT_FILE")
FLAKY=$(jq '[.. | objects | select(has("status")) | select(.status == "flaky")] | length' "$REPORT_FILE")
SKIPPED=$(jq '[.. | objects | select(has("status")) | select(.status == "skipped")] | length' "$REPORT_FILE")

TOTAL_TESTS=$((PASSED + FAILED + FLAKY + SKIPPED))

if [ "$FAILED" -gt 0 ]; then
    STATUS_TEXT="🔴QA Test Suite Completed"
    COLOR="#FF0000"
else
    STATUS_TEXT="🟢QA Test Suite Completed"
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
              "text": "Generated QA Automation CI | <${DASHBOARD_URL}|View Playwright HTML Report> | $(date '+%Y-%m-%d %H:%M:%S %Z')"
            }
          ]
        }
      ]
    }
  ]
}
EOF

echo ":: Slack payload saved to '$OUTPUT_PAYLOAD'."
