#!/usr/bin/env bash
# health-check.sh — Poll the health endpoint and report status
set -euo pipefail

TARGET_URL="${1:?Usage: $0 <url>}"
MAX_ATTEMPTS="${2:-20}"
SLEEP_SECS="${3:-10}"

echo "▶ Health checking $TARGET_URL (max $MAX_ATTEMPTS attempts)..."

for i in $(seq 1 "$MAX_ATTEMPTS"); do
  HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
    --max-time 10 \
    "$TARGET_URL/health" 2>/dev/null || echo "000")

  echo "  Attempt $i/$MAX_ATTEMPTS — HTTP $HTTP_CODE"

  if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ Service is healthy"
    exit 0
  fi

  [ "$i" -lt "$MAX_ATTEMPTS" ] && sleep "$SLEEP_SECS"
done

echo "❌ Service failed health checks after $MAX_ATTEMPTS attempts"
exit 1
