#!/usr/bin/env bash
# notify.sh
# Purpose: Post a status message to the configured webhook. Shared by CI
#          pipelines and (via Alertmanager) by Phase 5B alerting.
# depends_on: []
#
# usage: notify.sh <success|failure|info> <message>
#
# A blank ALERT_WEBHOOK_URL is not an error - notifications are optional and a
# missing webhook must never fail a build or an alert.

set -euo pipefail

STATUS="${1:-info}"
MESSAGE="${2:-}"

WEBHOOK="${ALERT_WEBHOOK_URL:-}"

if [ -z "$WEBHOOK" ]; then
  echo "notify: no ALERT_WEBHOOK_URL configured - skipping" >&2
  exit 0
fi

if [ -z "$MESSAGE" ]; then
  echo "notify: usage: notify.sh <success|failure|info> <message>" >&2
  exit 1
fi

case "$STATUS" in
  success) ICON="[OK]" ;;
  failure) ICON="[FAIL]" ;;
  *)       ICON="[INFO]" ;;
esac

# jq builds the JSON when available so a message containing quotes or newlines
# cannot break the payload; the fallback strips the characters that would.
if command -v jq >/dev/null 2>&1; then
  PAYLOAD=$(jq -nc --arg text "$ICON $MESSAGE" '{text: $text}')
else
  SAFE=$(printf '%s' "$MESSAGE" | tr -d '"\\' | tr '\n' ' ')
  PAYLOAD="{\"text\":\"$ICON $SAFE\"}"
fi

curl -sf -X POST \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" \
  "$WEBHOOK" >/dev/null \
  || { echo "notify: webhook POST failed (non-fatal)" >&2; exit 0; }

echo "notify: sent ($STATUS)" >&2
