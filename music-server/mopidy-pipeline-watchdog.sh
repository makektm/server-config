#!/bin/bash
# Watchdog: when Mopidy's gstreamer pipeline emits any "GStreamer error" but
# playback state stays "playing" (no audio out), recover automatically.
#
# Tiered recovery within a rolling window:
#   strikes 1..MAX_FIXES-1 : stop/play via JSON-RPC (cheap)
#   strike  MAX_FIXES      : escalate to `systemctl restart mopidy`
#   strikes > MAX_FIXES    : bail; persistent fault, leave it for a human

set -u

RPC_URL="http://localhost:6680/mopidy/rpc"
STATE_FILE="/run/mopidy-watchdog.timestamps"
MAX_FIXES=3
WINDOW_SECONDS=300

rpc() {
  curl -s -m 5 -X POST "$RPC_URL" \
    -H 'Content-Type: application/json' \
    -d "$1" >/dev/null
}

handle_error() {
  local now cutoff recent
  now=$(date +%s)
  cutoff=$((now - WINDOW_SECONDS))

  touch "$STATE_FILE"
  # Keep only timestamps inside the window
  awk -v c="$cutoff" '$1 > c' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  recent=$(wc -l < "$STATE_FILE")

  echo "$now" >> "$STATE_FILE"

  if (( recent < MAX_FIXES - 1 )); then
    logger -t mopidy-watchdog "gstreamer error; restarting playback (fix $((recent + 1))/$MAX_FIXES)"
    sleep 2
    rpc '{"jsonrpc":"2.0","id":1,"method":"core.playback.stop"}'
    sleep 1
    rpc '{"jsonrpc":"2.0","id":2,"method":"core.playback.play"}'
  elif (( recent == MAX_FIXES - 1 )); then
    logger -t mopidy-watchdog "gstreamer error; stop/play didn't stick — restarting mopidy.service (fix $((recent + 1))/$MAX_FIXES)"
    systemctl restart mopidy
  else
    logger -t mopidy-watchdog "rate limit hit ($recent in ${WINDOW_SECONDS}s) — giving up; investigate manually"
  fi
}

journalctl -fu mopidy -o cat --since now | while IFS= read -r line; do
  case "$line" in
    *"GStreamer error"*) handle_error ;;
  esac
done
