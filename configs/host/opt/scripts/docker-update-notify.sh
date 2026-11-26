#!/bin/bash
# /opt/scripts/docker-update-notify.sh
# Usage: docker-update-notify.sh <line count of the log before the run started>
LOG="/var/log/docker-update.log"
START_LINE="${1:-0}"

RUN_LOG=$(tail -n +"$((START_LINE + 1))" "$LOG")
UPDATED=$(echo "$RUN_LOG" | grep 'Update found' | sed -E 's/.*tearing down //')
ERRORS=$(echo "$RUN_LOG" | grep -E 'Error response from daemon|ERROR: |failed to (solve|pull|create|start|resolve)' | head -10)

# Stay quiet unless something was updated or went wrong.
[ -z "$UPDATED" ] && [ -z "$ERRORS" ] && exit 0

if [ -n "$ERRORS" ]; then STATUS="problems"; else STATUS="updated"; fi
{
  [ -n "$UPDATED" ] && { echo "Updated:"; echo "$UPDATED"; echo; }
  [ -n "$ERRORS" ] && { echo "Errors:"; echo "$ERRORS"; }
} | head -c 3500 | /usr/sbin/sendmail -s "Docker update on $(hostname): $STATUS" root
