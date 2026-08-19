#!/usr/bin/env bash

## generate-deployment-notification.sh
##
## Build and send the Slack payload announcing the start or completion of an
## environment deployment
##
## usage $0 [Status] [Release version] [Pipeline URL] [Application Overview dashboard URL] [B2B notification URL] [B2C notification URL] [Slack webhook URL]
## Required arguments
## [$1] - Status: "Started" or "Completed"
## [$2] - Release version (e.g. 18.8.50)
## [$3] - Link to the pipeline run
## [$4] - Link to the Application Overview dashboard
## [$5] - Link to the B2B notification endpoint
## [$6] - Link to the B2C notification endpoint
## [$7] - Slack incoming webhook URL to post the payload to
set -euo pipefail

STATUS="$1"
RELEASE_VERSION="$2"
PIPELINE_URL="$3"
DASHBOARD_URL="$4"
B2B_NOTIFICATION_URL="$5"
B2C_NOTIFICATION_URL="$6"
WEBHOOK_URL="$7"
OUTPUT_PAYLOAD="slack_payload.json"

case "$STATUS" in
  Started)
    COLOUR="#439FE0"
    ;;
  Completed)
    COLOUR="#36A64F"
    ;;
  *)
    COLOUR="#CCCCCC"
    ;;
esac

cat <<EOF > "$OUTPUT_PAYLOAD"
{
  "attachments": [
    {
      "color": "${COLOUR}",
      "blocks": [
        {
          "type": "header",
          "text": {
            "type": "plain_text",
            "text": "Deployment ${STATUS}",
            "emoji": true
          }
        },
        {
          "type": "section",
          "text": {
            "type": "mrkdwn",
            "text": "${RELEASE_VERSION}"
          }
        },
        {
          "type": "section",
          "text": {
            "type": "mrkdwn",
            "text": "<${PIPELINE_URL}|View pipeline> | <${DASHBOARD_URL}|Application Overview>"
          }
        },
        {
          "type": "section",
          "text": {
            "type": "mrkdwn",
            "text": "<${B2B_NOTIFICATION_URL}|B2B Notification Part 1> | <${B2C_NOTIFICATION_URL}|B2C Notification Part 1>"
          }
        }
      ]
    }
  ]
}
EOF

echo ":: Slack payload saved to '$OUTPUT_PAYLOAD'."

curl -X POST -H 'Content-type: application/json' --data @"$OUTPUT_PAYLOAD" "$WEBHOOK_URL"
