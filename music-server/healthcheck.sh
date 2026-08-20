#!/bin/bash
# One-shot status report for the music server stack: services, resources,
# Bluetooth, caches, and a *live* Spotify auth probe (service "active" does
# not mean Spotify lookups actually work — see mopidy-spotify-login-watchdog.sh
# for why). Replaces the usual routine of SSHing in and running a dozen
# separate systemctl/journalctl/curl commands by hand.
#
# Usage: ./healthcheck.sh          (run on the Pi, or `ssh pi@host bash -s < healthcheck.sh`)
# Exit code: 0 if everything passed, 1 if anything failed.

set -u

RPC_URL="http://localhost:6680/mopidy/rpc"
FAIL_COUNT=0

pass() { printf "  \033[32mOK\033[0m    %s\n" "$1"; }
warn() { printf "  \033[33mWARN\033[0m  %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo "=== Music Server Health Check — $(date) ==="

echo
echo "[Services]"
for s in mopidy raspotify bluealsa bluetooth mopidy-pipeline-watchdog mopidy-spotify-login-watchdog; do
  if ! systemctl list-unit-files "${s}.service" 2>/dev/null | grep -q "$s"; then
    warn "$s: not installed"
    continue
  fi
  active=$(systemctl is-active "$s" 2>&1)
  enabled=$(systemctl is-enabled "$s" 2>&1)
  if [ "$active" = "active" ]; then
    pass "$s: active ($enabled)"
  else
    fail "$s: $active ($enabled)"
  fi
done

echo
echo "[Resources]"
read -r mem_total mem_avail < <(free -m | awk '/^Mem:/{print $2, $7}')
if [ "$mem_avail" -lt 50 ]; then
  fail "Memory: ${mem_avail}MiB available of ${mem_total}MiB (low)"
else
  pass "Memory: ${mem_avail}MiB available of ${mem_total}MiB"
fi

disk_pct=$(df -P / | awk 'NR==2{gsub("%","",$5); print $5}')
disk_avail=$(df -Ph / | awk 'NR==2{print $4}')
if [ "$disk_pct" -ge 95 ]; then
  fail "Disk (/): ${disk_pct}% used, ${disk_avail} free"
elif [ "$disk_pct" -ge 85 ]; then
  warn "Disk (/): ${disk_pct}% used, ${disk_avail} free"
else
  pass "Disk (/): ${disk_pct}% used, ${disk_avail} free"
fi

if command -v vcgencmd &>/dev/null; then
  throttled=$(vcgencmd get_throttled 2>&1 | cut -d= -f2)
  if [ "$throttled" = "0x0" ]; then
    pass "Power/thermal throttling: none"
  else
    fail "Power/thermal throttling flags set: $throttled (see vcgencmd docs for bit meanings)"
  fi
fi

echo
echo "[Bluetooth]"
connected=$(bluetoothctl devices Connected 2>&1)
if [ -n "$connected" ]; then
  pass "Speaker connected: $(echo "$connected" | head -1 | cut -d' ' -f3-)"
else
  fail "No Bluetooth audio device connected"
fi

echo
echo "[Caches]"
if [ -d /var/cache/mopidy/spotify ]; then
  spotify_cache_mb=$(sudo du -sm /var/cache/mopidy/spotify 2>/dev/null | cut -f1)
  if [ -z "$spotify_cache_mb" ]; then
    warn "spotify audio cache: could not read size (needs passwordless sudo — check with 'sudo -n true')"
  else
    cap_mb=$(grep -A20 '^\[spotify\]' /etc/mopidy/mopidy.conf 2>/dev/null | grep -m1 '^cache_size' | cut -d= -f2 | tr -d ' ')
    cap_mb=${cap_mb:-8192}
    if [ "$spotify_cache_mb" -ge "$cap_mb" ]; then
      warn "spotify audio cache: ${spotify_cache_mb}MiB (at its ${cap_mb}MiB cap — eating disk space)"
    else
      pass "spotify audio cache: ${spotify_cache_mb}MiB (cap ${cap_mb}MiB)"
    fi
  fi
fi
if [ -d /var/cache/mopidy/bandcamp ]; then
  bc_cache_mb=$(sudo du -sm /var/cache/mopidy/bandcamp 2>/dev/null | cut -f1)
  if [ -z "$bc_cache_mb" ]; then
    warn "bandcamp cache: could not read size (needs passwordless sudo — check with 'sudo -n true')"
  else
    pass "bandcamp cache: ${bc_cache_mb}MiB"
  fi
fi

echo
echo "[Live Spotify auth check]"
search_result=$(curl -sS -m 8 -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"core.library.search","params":{"query":{"any":["a"]},"uris":["spotify:"]}}' \
  "$RPC_URL" 2>&1)
if echo "$search_result" | grep -q '"tracks"'; then
  pass "Spotify search returned real results (login OK)"
elif echo "$search_result" | grep -qi "not logged in\|error"; then
  fail "Spotify search failed — backend not logged in. Fix: sudo systemctl restart mopidy"
else
  warn "Could not reach Mopidy RPC at $RPC_URL — is mopidy running?"
fi

echo
echo "[Recent errors — last 15 min]"
recent_errors=$(journalctl -u mopidy --since "15 min ago" --no-pager 2>&1 | \
  grep -iE "GStreamer error|Not logged in|OAuth token refresh failed|Password-less access" | \
  sort -u)
if [ -n "$recent_errors" ]; then
  warn "found known error patterns in the last 15 min:"
  echo "$recent_errors" | sed 's/^/    /'
else
  pass "no known error patterns in the last 15 min"
fi

echo
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "=== All checks passed ==="
  exit 0
else
  echo "=== $FAIL_COUNT check(s) failed — see FAIL lines above ==="
  exit 1
fi
