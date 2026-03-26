#!/bin/bash
# RPi Zero 2 W — Music Server Setup Script
# Run on the Pi as: sudo bash setup.sh
#
# Installs: BlueALSA (Bluetooth audio via ALSA), Raspotify (Spotify Connect),
#           Mopidy + Bandcamp + Iris (Bandcamp streaming with web UI)
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
echo "[1/7] Installing system packages..."
apt update
apt install -y \
  bluez \
  bluez-alsa-utils \
  mopidy \
  python3-pip

# --- 2. Raspotify ---
echo "[2/7] Installing Raspotify..."
if ! command -v raspotify &> /dev/null && ! systemctl list-unit-files | grep -q raspotify; then
  curl -sL https://dtcooper.github.io/raspotify/install.sh | sh
else
  echo "  Raspotify already installed, skipping."
fi

# --- 3. Mopidy extensions ---
echo "[3/7] Installing Mopidy-Bandcamp and Mopidy-Iris..."
pip3 install --break-system-packages Mopidy-Bandcamp Mopidy-Iris 2>/dev/null \
  || pip3 install Mopidy-Bandcamp Mopidy-Iris

# --- 4. Copy config files ---
echo "[4/7] Copying configuration files..."

# ALSA config — substitute MAC address
sed "s/XX:XX:XX:XX:XX:XX/$C50BT_MAC/g" "$SCRIPT_DIR/asound.conf" \
  > /etc/asound.conf
echo "  -> /etc/asound.conf (MAC: $C50BT_MAC)"

# Mopidy config
cp "$SCRIPT_DIR/mopidy.conf" /etc/mopidy/mopidy.conf
echo "  -> /etc/mopidy/mopidy.conf"

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

# --- 5. Add mopidy user to bluetooth group ---
echo "[5/7] Configuring permissions..."
usermod -aG bluetooth mopidy
echo "  Added mopidy user to bluetooth group."

# --- 6. Enable services ---
echo "[6/7] Enabling services..."
systemctl daemon-reload

systemctl enable bluealsa
systemctl restart bluealsa

systemctl enable mopidy
systemctl restart mopidy

systemctl enable raspotify
systemctl restart raspotify

# Only enable bt-auto-connect if MAC was changed from placeholder
if [ "$C50BT_MAC" != "XX:XX:XX:XX:XX:XX" ]; then
  systemctl enable bt-auto-connect
  echo "  bt-auto-connect service enabled."
else
  echo "  WARNING: C50BT MAC address not set. Edit C50BT_MAC in this script and re-run,"
  echo "  or manually enable: sudo systemctl enable bt-auto-connect"
fi

# --- 7. Done ---
echo ""
echo "[7/7] Setup complete!"
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
echo "3. TEST SPOTIFY:"
echo "   Open Spotify on your phone → Devices → 'MakeKTM Pi'"
echo ""
echo "4. TEST BANDCAMP:"
echo "   Open http://192.168.1.186:6680/iris in a browser"
echo ""
echo "5. UPDATE C50BT MAC (if not already done):"
echo "   Edit C50BT_MAC at the top of this script, then re-run it."
echo ""
echo "6. VERIFY PRINT SERVER STILL WORKS:"
echo "   lpstat -p"
echo "   echo 'test' | lp"
