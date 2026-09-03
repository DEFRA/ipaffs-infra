#!/usr/bin/env bash

## generate-deployment-notification.sh
##
## Build and send the Slack payload announcing the start or completion of an
## environment deployment
##
## usage $0 [Status] [Release version] [Pipeline URL] [Dashboard URL] [B2B notification URL] [B2C notification URL] [Slack webhook URL] [Dashboard label]
## Required arguments
## [$1] - Status: "Started" or "Completed"
## [$2] - Release version (e.g. 18.8.50)
## [$3] - Link to the pipeline run
## [$4] - Link to the deployment dashboard
## [$5] - Link to the B2B notification endpoint (optional; pass an empty string to omit)
## [$6] - Link to the B2C notification endpoint (optional; pass an empty string to omit)
## [$7] - Slack incoming webhook URL to post the payload to
## Optional arguments
## [$8] - Dashboard link label (defaults to "Application Overview")
set -euo pipefail

if (( $# < 7 || $# > 8 )); then
  echo "Usage: $0 [Status] [Release version] [Pipeline URL] [Dashboard URL] [B2B notification URL] [B2C notification URL] [Slack webhook URL] [Dashboard label]" >&2
  exit 2
fi

STATUS="$1"
RELEASE_VERSION="$2"
PIPELINE_URL="$3"
DASHBOARD_URL="$4"
B2B_NOTIFICATION_URL="$5"
B2C_NOTIFICATION_URL="$6"
WEBHOOK_URL="$7"
DASHBOARD_LABEL="${8:-Application Overview}"
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

ADDITIONAL_LINKS=""

if [[ -n "$B2B_NOTIFICATION_URL" ]]; then
  ADDITIONAL_LINKS="<${B2B_NOTIFICATION_URL}|B2B Notification Part 1>"
fi

if [[ -n "$B2C_NOTIFICATION_URL" ]]; then
  if [[ -n "$ADDITIONAL_LINKS" ]]; then
    ADDITIONAL_LINKS+=" | "
  fi

  ADDITIONAL_LINKS+="<${B2C_NOTIFICATION_URL}|B2C Notification Part 1>"
fi

ADDITIONAL_LINKS_BLOCK=""

if [[ -n "$ADDITIONAL_LINKS" ]]; then
  ADDITIONAL_LINKS_BLOCK=$(cat <<EOF
,
        {
          "type": "section",
          "text": {
            "type": "mrkdwn",
            "text": "${ADDITIONAL_LINKS}"
          }
        }
EOF
)
fi

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
            "text": "<${PIPELINE_URL}|View pipeline> | <${DASHBOARD_URL}|${DASHBOARD_LABEL}>"
          }
        }${ADDITIONAL_LINKS_BLOCK}
      ]
    }
  ]
}
EOF

echo ":: Slack payload saved to '$OUTPUT_PAYLOAD'."

curl -X POST -H 'Content-type: application/json' --data @"$OUTPUT_PAYLOAD" "$WEBHOOK_URL"
