#!/usr/bin/env bash

## parse-playwright-results.sh
##
## Parse Playwright results.json file
##
## usage $0 [Playwright results file] [Link to Playwright report view] [Previous Playwright results file]
## Required arguments
## [$1] - Playwright results file
## [$2] - Playwright report view URL
## [$3] - Previous Playwright results file (optional)

set -euo pipefail

REPORT_FILE="${1:-results.json}"
DASHBOARD_URL="$2"
PREVIOUS_REPORT_FILE="${3:-}"
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

extract_status_map() {
  local file="$1"
  jq -r '
    [.. | objects | select(has("status")) |
      {status:.status, title:(.title // .name // ""), file:(try .location.file // .file // ""), ancestors:(.ancestorTitles // .ancestorTitle // [])}]
    | map({key: ([.file] + (.ancestors // []) + [.title] | map(select(. != null and . != "")) | join(" > ")), status:.status})
    | map("\(.key)\t\(.status)")[]' "$file"
}

NEW_FAILURES=0
PERSISTENT_FAILURES=0
FIXED=0
COMPARISON_TEXT="No previous report comparison available."

if [ -n "$PREVIOUS_REPORT_FILE" ] && [ -f "$PREVIOUS_REPORT_FILE" ]; then
  CURRENT_TEMP=$(mktemp)
  PREVIOUS_TEMP=$(mktemp)
  trap 'rm -f "$CURRENT_TEMP" "$PREVIOUS_TEMP"' EXIT

  extract_status_map "$REPORT_FILE" > "$CURRENT_TEMP"
  extract_status_map "$PREVIOUS_REPORT_FILE" > "$PREVIOUS_TEMP"

  while IFS=$'\t' read -r key status; do
    previous_status_value=$(grep -F -- "${key}" "$PREVIOUS_TEMP" | tail -n 1 | cut -f2-)

    if [ "$status" = "unexpected" ]; then
      if [ "$previous_status_value" = "unexpected" ]; then
        ((PERSISTENT_FAILURES++))
      else
        ((NEW_FAILURES++))
      fi
    fi

    if [ "$previous_status_value" = "unexpected" ] && [ "$status" = "expected" ]; then
      ((FIXED++))
    fi
  done < "$CURRENT_TEMP"

  COMPARISON_TEXT="Compared to previous run:"
elif [ -n "$PREVIOUS_REPORT_FILE" ]; then
  echo ":: Previous Playwright report file '$PREVIOUS_REPORT_FILE' not found. Skipping run comparison." >&2
fi

TOTAL_TESTS=$((PASSED + FAILED + FLAKY + SKIPPED))

if [ "$FAILED" -gt 0 ]; then
    STATUS_TEXT="🔴- QA Test Suite Completed"
    COLOR="#FF0000"
else
    STATUS_TEXT="🟢- QA Test Suite Completed"
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
          "type": "section",
          "fields": [
            { "type": "mrkdwn", "text": "New Failures : $NEW_FAILURES" },
            { "type": "mrkdwn", "text": "Persistent Failures : $PERSISTENT_FAILURES" },
            { "type": "mrkdwn", "text": "Fixed : $FIXED" }
          ]
        },
        {
          "type": "context",
          "elements": [
            {
              "type": "mrkdwn",
              "text": "$COMPARISON_TEXT | Generated QA Automation CI | <${DASHBOARD_URL}|View Playwright Report> | $(date '+%Y-%m-%d %H:%M:%S %Z')"
            }
          ]
        }
      ]
    }
  ]
}
EOF

echo ":: Slack payload saved to '$OUTPUT_PAYLOAD'."
