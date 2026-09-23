#!/bin/bash
payload=$(cat)
session_id=$(echo "$payload" | jq -r '.session_id // "default"' 2>/dev/null)
rm -f "/tmp/claude-notif-pending-${session_id}"
