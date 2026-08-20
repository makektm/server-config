#!/bin/bash
# RPi Zero 2 W — Music Server Setup Script
# Run on the Pi as: sudo bash setup.sh
#
# Installs: BlueALSA (Bluetooth audio via ALSA), Raspotify (Spotify Connect),
#           Mopidy + Bandcamp + Spotify + Iris (music streaming with web UI)
#
# Prerequisites:
#   - Raspberry Pi OS Lite 32-bit (trixie/ARMv7) already running
#   - Internet connection
#   - C50BT Bluetooth speaker (pairing is manual — see instructions at end)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
C50BT_MAC="AE:EC:81:96:06:B7"

echo "=== RPi Music Server Setup ==="
echo ""

# --- Check root ---
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: Run this script with sudo."
  exit 1
fi

# --- 1. System packages ---
echo "[1/9] Installing system packages..."
apt update
apt install -y \
  bluez \
  bluez-alsa-utils \
  mopidy \
  python3-pip
# --no-install-recommends: gstreamer1.0-plugins-bad pulls in ~40 optional
# codec/GUI libs we don't need — we only want the `watchdog` element.
apt install -y --no-install-recommends gstreamer1.0-plugins-bad

# --- 2. Raspotify ---
echo "[2/9] Installing Raspotify..."
if ! command -v raspotify &> /dev/null && ! systemctl list-unit-files | grep -q raspotify; then
  curl -sL https://dtcooper.github.io/raspotify/install.sh | sh
else
  echo "  Raspotify already installed, skipping."
fi

# --- 3. GStreamer Spotify plugin (for Mopidy-Spotify audio playback) ---
echo "[3/9] Installing gst-plugin-spotify..."
GST_SPOTIFY_DEB="gst-plugin-spotify_0.15.0.alpha.1-4_armhf.deb"
GST_SPOTIFY_URL="https://github.com/kingosticks/gst-plugins-rs-build/releases/download/gst-plugin-spotify_0.15.0-alpha.1-4/$GST_SPOTIFY_DEB"
if ! gst-inspect-1.0 spotifyaudiosrc &>/dev/null; then
  wget -q -O "/tmp/$GST_SPOTIFY_DEB" "$GST_SPOTIFY_URL"
  # --force-depends: the .deb expects libglib2.0-0 but trixie renamed it to libglib2.0-0t64
  dpkg --force-depends -i "/tmp/$GST_SPOTIFY_DEB"
  rm -f "/tmp/$GST_SPOTIFY_DEB"
  echo "  gst-plugin-spotify installed."
else
  echo "  gst-plugin-spotify already installed, skipping."
fi

# --- 4. Mopidy extensions ---
# Mopidy-Spotify 5.x requires Mopidy 4.x (pip), which replaces the apt Mopidy 3.x.
# We first upgrade typing-extensions (needed by pydantic/Mopidy 4.x) using --target
# to avoid pip refusing to uninstall the Debian-managed version, then install everything.
echo "[4/9] Installing Mopidy extensions..."
pip3 install --break-system-packages \
  --target=/usr/local/lib/python3.13/dist-packages \
  "typing-extensions>=4.14.1"
# Iris: install from develop branch (has Mopidy 4.x compat fixes not yet released)
pip3 install --break-system-packages \
  Mopidy-Bandcamp Mopidy-ALSAMixer Mopidy-MPD==4.0.0a4 \
  Mopidy-Spotify==5.0.0a7 \
  "git+https://github.com/jaedb/Iris.git@develop"

# Patch Mopidy-Bandcamp: pydantic v2 rejects musicbrainz_id="" (empty string is not a
# valid UUID). Replace with None. Re-apply after upgrading Mopidy-Bandcamp.
BANDCAMP_DIR=$(python3 -c "import mopidy_bandcamp; import os; print(os.path.dirname(mopidy_bandcamp.__file__))" 2>/dev/null)
BANDCAMP_LIB="$BANDCAMP_DIR/library.py"
BANDCAMP_INIT="$BANDCAMP_DIR/__init__.py"
if [ -f "$BANDCAMP_LIB" ]; then
  sed -i 's/musicbrainz_id=""/musicbrainz_id=None/g' "$BANDCAMP_LIB"
  echo "  Patched mopidy-bandcamp: musicbrainz_id=\"\" -> None"
else
  echo "  WARNING: mopidy-bandcamp library.py not found at $BANDCAMP_LIB — patch skipped"
fi

# Install bandcamp disk cache addon. Upstream mopidy-bandcamp makes one HTTPS
# round-trip per lookup with no cache; loading a 67-track playlist takes ~38s
# on the Pi Zero 2 W (Iris times out → 0 tracks displayed). Cache survives
# restarts and is invalidated after 1 year.
if [ -d "$BANDCAMP_DIR" ]; then
  install -m 644 "$SCRIPT_DIR/mopidy_bandcamp_cache.py" "$BANDCAMP_DIR/_cache.py"
  if ! grep -q "from . import _cache" "$BANDCAMP_INIT"; then
    echo "from . import _cache  # noqa: F401  -- disk cache addon" >> "$BANDCAMP_INIT"
  fi
  install -d -o mopidy -g audio -m 755 /var/cache/mopidy/bandcamp
  echo "  Installed mopidy-bandcamp disk cache (cache dir: /var/cache/mopidy/bandcamp)"
fi

# --- 5. Copy config files ---
echo "[5/9] Copying configuration files..."

# ALSA config — substitute MAC address
sed "s/XX:XX:XX:XX:XX:XX/$C50BT_MAC/g" "$SCRIPT_DIR/asound.conf" \
  > /etc/asound.conf
echo "  -> /etc/asound.conf (MAC: $C50BT_MAC)"

# Mopidy config
cp "$SCRIPT_DIR/mopidy.conf" /etc/mopidy/mopidy.conf
echo "  -> /etc/mopidy/mopidy.conf"

# Spotify secrets (conf.d overlay — not tracked in git)
mkdir -p /etc/mopidy/conf.d
if [ ! -f /etc/mopidy/conf.d/spotify-secrets.conf ]; then
  cat > /etc/mopidy/conf.d/spotify-secrets.conf <<'SPOTIFY_SECRETS'
[spotify]
client_id = PASTE_YOUR_CLIENT_ID_HERE
client_secret = PASTE_YOUR_CLIENT_SECRET_HERE
SPOTIFY_SECRETS
  chown mopidy:audio /etc/mopidy/conf.d/spotify-secrets.conf
  chmod 640 /etc/mopidy/conf.d/spotify-secrets.conf
  echo "  -> /etc/mopidy/conf.d/spotify-secrets.conf (EDIT THIS — add your Spotify credentials)"
else
  echo "  -> /etc/mopidy/conf.d/spotify-secrets.conf already exists, preserving."
fi

# Raspotify config
mkdir -p /etc/raspotify
cp "$SCRIPT_DIR/raspotify.conf" /etc/raspotify/conf
echo "  -> /etc/raspotify/conf"

# Raspotify systemd override (allow AF_BLUETOOTH)
mkdir -p /etc/systemd/system/raspotify.service.d
cp "$SCRIPT_DIR/raspotify-override.conf" /etc/systemd/system/raspotify.service.d/override.conf
echo "  -> /etc/systemd/system/raspotify.service.d/override.conf"

# BlueALSA systemd override (keep-alive prevents transport teardown between tracks)
mkdir -p /etc/systemd/system/bluealsa.service.d
cp "$SCRIPT_DIR/bluealsa-override.conf" /etc/systemd/system/bluealsa.service.d/override.conf
echo "  -> /etc/systemd/system/bluealsa.service.d/override.conf"

# bt-auto-connect service — substitute the MAC address
sed "s/XX:XX:XX:XX:XX:XX/$C50BT_MAC/g" "$SCRIPT_DIR/bt-auto-connect.service" \
  > /etc/systemd/system/bt-auto-connect.service
echo "  -> /etc/systemd/system/bt-auto-connect.service (MAC: $C50BT_MAC)"

# bt-softvol-init service — initializes BTVolume ALSA control on boot
cp "$SCRIPT_DIR/bt-softvol-init.service" /etc/systemd/system/bt-softvol-init.service
echo "  -> /etc/systemd/system/bt-softvol-init.service"

# mopidy-pipeline-watchdog: restart playback if gstreamer pipeline dies
install -m 755 "$SCRIPT_DIR/mopidy-pipeline-watchdog.sh" /usr/local/bin/mopidy-pipeline-watchdog.sh
cp "$SCRIPT_DIR/mopidy-pipeline-watchdog.service" /etc/systemd/system/mopidy-pipeline-watchdog.service
echo "  -> /usr/local/bin/mopidy-pipeline-watchdog.sh"
echo "  -> /etc/systemd/system/mopidy-pipeline-watchdog.service"

# mopidy-spotify-login-watchdog: restart mopidy if Spotify OAuth login gets
# stuck "Not logged in" (boot-race — mopidy-spotify never retries on its own)
install -m 755 "$SCRIPT_DIR/mopidy-spotify-login-watchdog.sh" /usr/local/bin/mopidy-spotify-login-watchdog.sh
cp "$SCRIPT_DIR/mopidy-spotify-login-watchdog.service" /etc/systemd/system/mopidy-spotify-login-watchdog.service
echo "  -> /usr/local/bin/mopidy-spotify-login-watchdog.sh"
echo "  -> /etc/systemd/system/mopidy-spotify-login-watchdog.service"

# healthcheck.sh: one-shot status report (services, resources, live Spotify probe)
install -m 755 "$SCRIPT_DIR/healthcheck.sh" /usr/local/bin/music-server-healthcheck
echo "  -> /usr/local/bin/music-server-healthcheck"

# Iris system-actions sudoers rule (restart/upgrade/scan buttons in the Iris UI)
install -m 440 -o root -g root "$SCRIPT_DIR/mopidy-iris-sudoers" /etc/sudoers.d/mopidy-iris
visudo -c -f /etc/sudoers.d/mopidy-iris || { echo "ERROR: mopidy-iris-sudoers failed validation, removing it"; rm -f /etc/sudoers.d/mopidy-iris; }
echo "  -> /etc/sudoers.d/mopidy-iris"

# Mopidy systemd override:
#  - Use pip-installed mopidy 4.x binary (not apt's 3.x at /usr/bin/mopidy)
#  - Include /etc/mopidy/conf.d for secrets overlay (spotify credentials)
#  - Wait for softvol init before starting
mkdir -p /etc/systemd/system/mopidy.service.d
cat > /etc/systemd/system/mopidy.service.d/override.conf <<'MOPIDY_OVERRIDE'
[Unit]
After=bt-softvol-init.service
Wants=bt-softvol-init.service

[Service]
ExecStart=
ExecStart=/usr/local/bin/mopidy --config /usr/share/mopidy/conf.d:/etc/mopidy/conf.d:/etc/mopidy/mopidy.conf
MOPIDY_OVERRIDE
echo "  -> /etc/systemd/system/mopidy.service.d/override.conf"

# --- 6. Prefer ethernet over WiFi ---
echo "[6/9] Configuring network (prefer ethernet over WiFi)..."

# Dispatcher script: disable WiFi when eth0 is up, re-enable when down
cp "$SCRIPT_DIR/prefer-ethernet.sh" /etc/NetworkManager/dispatcher.d/99-prefer-ethernet
chmod 755 /etc/NetworkManager/dispatcher.d/99-prefer-ethernet
echo "  -> /etc/NetworkManager/dispatcher.d/99-prefer-ethernet"

# Set eth0 to static IP 192.168.1.186 so the Pi keeps the same address
# whether connected via ethernet or WiFi
nmcli connection modify netplan-eth0 \
  ipv4.method manual \
  ipv4.addresses 192.168.1.186/24 \
  ipv4.gateway 192.168.1.254 \
  ipv4.dns "192.168.1.254" 2>/dev/null \
  && echo "  eth0 set to static IP 192.168.1.186" \
  || echo "  (eth0 not present — skipped static IP config)"

# --- 7. Add mopidy user to bluetooth group ---
echo "[7/9] Configuring permissions..."
usermod -aG bluetooth mopidy
echo "  Added mopidy user to bluetooth group."

# --- 8. Enable services ---
echo "[8/9] Enabling services..."
systemctl daemon-reload

systemctl enable bluealsa
systemctl restart bluealsa

systemctl enable bt-softvol-init
systemctl enable mopidy
systemctl restart mopidy

systemctl enable raspotify
systemctl restart raspotify

systemctl enable mopidy-pipeline-watchdog
systemctl restart mopidy-pipeline-watchdog

systemctl enable mopidy-spotify-login-watchdog
systemctl restart mopidy-spotify-login-watchdog

# Only enable bt-auto-connect if MAC was changed from placeholder
if [ "$C50BT_MAC" != "XX:XX:XX:XX:XX:XX" ]; then
  systemctl enable bt-auto-connect
  echo "  bt-auto-connect service enabled."
else
  echo "  WARNING: C50BT MAC address not set. Edit C50BT_MAC in this script and re-run,"
  echo "  or manually enable: sudo systemctl enable bt-auto-connect"
fi

# --- 9. Done ---
echo ""
echo "[9/9] Setup complete!"
echo ""
echo "=== NEXT STEPS ==="
echo ""
echo "1. PAIR THE C50BT BLUETOOTH SPEAKER (manual step):"
echo "   Turn on the C50BT and put it in pairing mode, then run:"
echo ""
echo "     bluetoothctl"
echo "     > power on"
echo "     > agent on"
echo "     > scan on"
echo "     (wait for C50BT to appear, note MAC address)"
echo "     > pair <MAC>"
echo "     > trust <MAC>"
echo "     > connect <MAC>"
echo "     > quit"
echo ""
echo "2. TEST AUDIO:"
echo "   aplay -D btspeaker /usr/share/sounds/alsa/Front_Center.wav"
echo ""
echo "3. CONFIGURE SPOTIFY (in Mopidy):"
echo "   a. Get client_id + client_secret at https://mopidy.com/ext/spotify/#authentication"
echo "   b. Edit /etc/mopidy/mopidy.conf → [spotify] section"
echo "   c. sudo systemctl restart mopidy"
echo "   d. Check logs: journalctl -u mopidy -f (look for OAuth prompt on first run)"
echo ""
echo "4. TEST SPOTIFY CONNECT (Raspotify):"
echo "   Open Spotify on your phone → Devices → 'MakeKTM Pi'"
echo ""
echo "5. TEST BANDCAMP + SPOTIFY (Iris):"
echo "   Open http://192.168.1.186:6680/iris in a browser"
echo "   Search for Spotify tracks, albums, playlists"
echo ""
echo "6. UPDATE C50BT MAC (if not already done):"
echo "   Edit C50BT_MAC at the top of this script, then re-run it."
echo ""
echo "7. VERIFY PRINT SERVER STILL WORKS:"
echo "   lpstat -p"
echo "   echo 'test' | lp"
