#!/bin/bash
IFS=$'\t' read -r session_id message < <(jq -r '[.session_id // "default", .message // ""] | @tsv' 2>/dev/null)
session_id="${session_id:-default}"
delay="${NOTIF_DELAY_SECONDS:-60}"
marker="/tmp/claude-notif-pending-${session_id}"

# __CFBundleIdentifier is set by macOS to the bundle ID of the app that spawned
# this shell (e.g. IntelliJ IDEA's terminal panel vs. Ghostty), so clicking the
# notification activates whichever app Claude Code is actually running in.
activate_bundle_id="${__CFBundleIdentifier:-com.mitchellh.ghostty}"

notify() {
  terminal-notifier -title "Claude Code" -message "$1" -sound Ping -contentImage ~/.claude/hooks/assets/claude.png -activate "$activate_bundle_id" >/dev/null 2>&1 || true
}

if [ -z "$message" ]; then
  message="Claude needs your input"
elif ! echo "$message" | grep -qiE '\?|\bpermission\b|\bwaiting\b|\binput\b|\bconfirm\b|\bapprove\b|\bshould i\b|\bneed you\b|\bblocked\b|\bpending\b|\bdecision\b'; then
  # Backstop: suppress notifications that don't signal a real pending question/decision.
  exit 0
fi

# Already waiting on a response for this session -> don't stack another timer (no spamming).
[ -f "$marker" ] && exit 0

echo "$message" > "$marker"

# Only notify if the user hasn't responded (marker still present) after the delay.
( sleep "$delay"
  if [ -f "$marker" ]; then
    saved=$(cat "$marker" 2>/dev/null)
    rm -f "$marker"
    [ -n "$saved" ] && notify "$saved"
  fi
) </dev/null >/dev/null 2>&1 &
disown

exit 0
