#!/bin/bash
# Watchdog: when Mopidy's gstreamer pipeline dies with "Internal data stream
# error" but playback state stays "playing" (no audio out), restart playback
# via the Mopidy JSON-RPC API. Rate-limited so a bad track / persistent fault
# doesn't loop forever.

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

  if (( recent >= MAX_FIXES )); then
    logger -t mopidy-watchdog "rate limit hit ($recent/$MAX_FIXES in ${WINDOW_SECONDS}s) — not restarting playback"
    return
  fi

  echo "$now" >> "$STATE_FILE"
  logger -t mopidy-watchdog "gstreamer pipeline died; restarting playback (fix $((recent + 1))/$MAX_FIXES)"

  sleep 2
  rpc '{"jsonrpc":"2.0","id":1,"method":"core.playback.stop"}'
  sleep 1
  rpc '{"jsonrpc":"2.0","id":2,"method":"core.playback.play"}'
}

journalctl -fu mopidy -o cat --since now | while IFS= read -r line; do
  case "$line" in
    *"Internal data stream error"*) handle_error ;;
  esac
done
