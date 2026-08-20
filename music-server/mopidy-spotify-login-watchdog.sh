#!/bin/bash
# Watchdog: Mopidy-Spotify's OAuth login can fail once (seen during a
# boot-time network race — Mopidy starts before the network is truly
# reachable, three retries burn through their 0.5/1/2s backoff, then it
# gives up with "OAuth token refresh failed") and, unlike Mopidy's own
# extensions, it does NOT retry after that. Every subsequent lookup then
# fails "Not logged in" for the rest of the process's life — search, browse,
# and "add to queue" all silently return nothing until Mopidy is restarted.
# A fresh process re-authenticates in ~2 seconds every time, so a restart is
# a full, reliable fix.
#
# Tiered like mopidy-pipeline-watchdog.sh, but with only one remedy tier —
# there's no cheap stop/play equivalent for a dead OAuth session:
#   strikes 1..MAX_RESTARTS-1 : `systemctl restart mopidy`
#   strikes > MAX_RESTARTS    : rate limit hit; bail, leave it for a human
#     (this is the signal that credentials are genuinely bad, not just a
#     boot-time fluke — e.g. revoked Spotify app access, wrong client
#     secret, or auth.mopidy.com itself down)
#
# A successful login resets the strike count, so occasional isolated
# errors (a single dropped request) don't trigger a restart.

set -u

STATE_FILE="/run/mopidy-spotify-watchdog.timestamps"
MAX_RESTARTS=2
WINDOW_SECONDS=600
STRIKE_THRESHOLD=2

strikes=0

restart_mopidy() {
  local now cutoff recent
  now=$(date +%s)
  cutoff=$((now - WINDOW_SECONDS))

  touch "$STATE_FILE"
  awk -v c="$cutoff" '$1 > c' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  recent=$(wc -l < "$STATE_FILE")

  if (( recent < MAX_RESTARTS )); then
    echo "$now" >> "$STATE_FILE"
    logger -t mopidy-spotify-watchdog "spotify backend stuck (not logged in x$STRIKE_THRESHOLD); restarting mopidy.service (restart $((recent + 1))/$MAX_RESTARTS)"
    systemctl restart mopidy
  else
    logger -t mopidy-spotify-watchdog "rate limit hit ($recent restarts in ${WINDOW_SECONDS}s) — giving up; check Spotify credentials / auth.mopidy.com manually"
  fi
}

# A small backlog (not `--since now`) covers the gap between mopidy.service
# being forked and this watchdog's own journalctl -f actually attaching —
# under boot-time CPU contention that gap could otherwise swallow the one
# OAuth-failure line this whole script exists to catch. Replaying up to 20s
# of old lines on a watchdog restart is harmless: the state-file rate limit
# below still caps actual `systemctl restart mopidy` calls.
journalctl -fu mopidy -o cat --since "-20 seconds" | while IFS= read -r line; do
  case "$line" in
    *"Logged into Spotify Web API"*)
      strikes=0
      ;;
    *"mopidy_spotify.lookup Not logged in"*|*"OAuth token refresh failed"*)
      strikes=$((strikes + 1))
      if (( strikes >= STRIKE_THRESHOLD )); then
        restart_mopidy
        strikes=0
      fi
      ;;
  esac
done
