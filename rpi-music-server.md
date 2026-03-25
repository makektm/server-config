# RPi Zero 2 W — Music Server (Spotify + Bandcamp)

## Problem

We want to stream music from **Spotify** and **Bandcamp** through the RPi Zero 2 W that already runs as a print server. Audio output is to a **C50BT Bluetooth speaker**. No cloud-dependent or SaaS-only solutions — everything runs locally on the Pi.

## Why This Approach

### Volumio / moOde (rejected)
These are full OS images that replace Raspberry Pi OS. Since the Pi already runs a print server on Raspbian, we can't use them without a second SD card or second Pi.

### PulseAudio (rejected)
Too heavy for the Pi Zero 2 W's 512MB RAM when combined with the existing print server stack. Adds ~15-30MB overhead for a daemon that isn't needed.

### Raspotify + Mopidy + Mopidy-Bandcamp + BlueALSA (chosen)
- **Raspotify** wraps librespot to make the Pi a Spotify Connect target. Lightweight (~7MB RAM), runs as a systemd daemon. Cast from any Spotify app.
- **Mopidy** is an extensible music server with a plugin ecosystem. **Mopidy-Bandcamp** adds Bandcamp search/playback. **Mopidy-Iris** adds a web UI.
- **BlueALSA** (`bluez-alsa`) bridges Bluetooth audio directly through ALSA — no PulseAudio or PipeWire needed. Minimal RAM overhead.
- All components install as packages/services on top of existing Raspbian — no OS changes needed.

### Why not Mopidy-Spotify?
Mopidy-Spotify v5.0 moved past the deprecated libspotify, but it's alpha quality, the GStreamer Rust plugin is hard to build for ARM, and it doesn't provide Spotify Connect (the Pi won't appear in the Spotify app). Raspotify is the proven, lightweight approach.

## Hardware

| Component | Details |
|-----------|---------|
| Print/music server | Raspberry Pi Zero 2 W |
| Printer | Canon LBP2900 (USB) — see [print server doc](rpi-print-server.md) |
| Speaker | C50BT (Bluetooth A2DP) |
| Network | WiFi (192.168.1.186) |

## Software Stack

| Component | Role |
|-----------|------|
| Raspbian 13 (trixie), 32-bit ARMv7 | OS |
| [Raspotify](https://github.com/dtcooper/raspotify) | Spotify Connect daemon (librespot wrapper) |
| [Mopidy](https://mopidy.com/) | Music server framework |
| [Mopidy-Bandcamp](https://github.com/impliedchaos/mopidy-bandcamp) | Bandcamp search/playback plugin |
| [Mopidy-Iris](https://github.com/jaedb/Iris) | Web UI for Mopidy |
| [BlueALSA](https://github.com/Arkq/bluez-alsa) (`bluez-alsa-utils`) | Bluetooth A2DP audio via ALSA — no PulseAudio needed |
| BlueZ | Bluetooth pairing/connection |
| Existing: CUPS, Samba, captdriver | Print server (unchanged) |

## Audio Pipeline

```
Raspotify (librespot) ──→ ALSA "btspeaker" PCM ──→ BlueALSA ──→ Bluetooth A2DP ──→ C50BT
Mopidy (GStreamer)     ──→ ALSA "btspeaker" PCM ──→ BlueALSA ──→ Bluetooth A2DP ──→ C50BT
```

BlueALSA is single-stream — only one app can use the speaker at a time. Since Spotify and Bandcamp won't play simultaneously, this is fine.

## Resource Budget

| Service | Estimated RAM |
|---------|--------------|
| CUPS + Samba + captdriver | ~60-80MB |
| BlueALSA + BlueZ | ~5-10MB |
| Raspotify | ~7MB |
| Mopidy + Bandcamp + Iris | ~60-80MB |
| OS overhead | ~50MB |
| **Total** | **~180-230MB** |
| **Available (of ~437MB usable)** | **~210-260MB free** |

Lighter than PulseAudio. If RAM pressure becomes an issue, add a swap file or stop Mopidy when not in use.

## Setup

### Quick Setup (automated)

```bash
# On the Pi:
# 1. Copy the music-server/ directory to the Pi
scp -r server-config/music-server/ pi@192.168.1.186:/home/pi/music-server/

# 2. Edit the C50BT MAC address in setup.sh
nano /home/pi/music-server/setup.sh   # change C50BT_MAC="XX:XX:XX:XX:XX:XX"

# 3. Run the setup script
sudo bash /home/pi/music-server/setup.sh
```

The script installs all dependencies, copies config files, and enables services. Bluetooth pairing is the only manual step.

### Manual Setup (step by step)

#### 1. Install BlueALSA and BlueZ

```bash
sudo apt update
sudo apt install -y bluez bluez-alsa-utils
# bluez-alsa-utils pulls in libasound2-plugin-bluez automatically

sudo systemctl enable bluealsa
sudo systemctl start bluealsa
```

#### 2. Pair the C50BT

Turn on the C50BT and put it in pairing mode, then:

```bash
bluetoothctl
> power on
> agent on
> scan on
# Wait for C50BT to appear — note the MAC address (e.g. AA:BB:CC:DD:EE:FF)
> pair AA:BB:CC:DD:EE:FF
> trust AA:BB:CC:DD:EE:FF
> connect AA:BB:CC:DD:EE:FF
> quit
```

#### 3. Configure ALSA for BlueALSA

Copy the ALSA config (replace the MAC placeholder with your C50BT's actual MAC):

```bash
sudo sed 's/XX:XX:XX:XX:XX:XX/AA:BB:CC:DD:EE:FF/g' \
  /home/pi/music-server/asound.conf > /etc/asound.conf
```

This creates a named PCM `btspeaker` that routes audio through BlueALSA to the C50BT. Config must be in `/etc/asound.conf` (not `~/.asoundrc`) because Mopidy and Raspotify run as system services.

Test it:

```bash
aplay -D btspeaker /usr/share/sounds/alsa/Front_Center.wav
```

#### 4. Install Raspotify

```bash
curl -sL https://dtcooper.github.io/raspotify/install.sh | sh
```

Copy the config:

```bash
sudo cp /home/pi/music-server/raspotify.conf /etc/raspotify/conf
```

**Important**: Raspotify's systemd sandboxing blocks Bluetooth sockets by default. Apply the override:

```bash
sudo mkdir -p /etc/systemd/system/raspotify.service.d
sudo cp /home/pi/music-server/raspotify-override.conf \
  /etc/systemd/system/raspotify.service.d/override.conf
sudo systemctl daemon-reload
sudo systemctl enable raspotify
sudo systemctl restart raspotify
```

Config highlights (`/etc/raspotify/conf`):
- `LIBRESPOT_NAME="MakeKTM Pi"` — device name in Spotify
- `LIBRESPOT_BACKEND="alsa"` — ALSA backend (not PulseAudio)
- `LIBRESPOT_DEVICE="btspeaker"` — BlueALSA PCM from `/etc/asound.conf`
- `LIBRESPOT_BITRATE="320"` — max quality (Premium)

#### 5. Install Mopidy + Bandcamp + Iris

```bash
sudo apt install -y mopidy python3-pip
pip3 install --break-system-packages Mopidy-Bandcamp Mopidy-Iris
```

Add the `mopidy` user to the `bluetooth` group so it can access BlueALSA:

```bash
sudo usermod -aG bluetooth mopidy
```

Copy the config:

```bash
sudo cp /home/pi/music-server/mopidy.conf /etc/mopidy/mopidy.conf
sudo systemctl enable mopidy
sudo systemctl restart mopidy
```

Config highlights (`/etc/mopidy/mopidy.conf`):
- `output = alsasink device=btspeaker` — routes audio through BlueALSA → C50BT
- `hostname = 0.0.0.0` — Iris web UI accessible from LAN on port 6680
- Bandcamp identity cookie (optional) — enables access to purchased collection

#### 6. Auto-reconnect C50BT on boot

Bluetooth speakers need an explicit reconnect after power cycling. Install the systemd service:

```bash
sudo sed 's/XX:XX:XX:XX:XX:XX/AA:BB:CC:DD:EE:FF/g' \
  /home/pi/music-server/bt-auto-connect.service \
  > /etc/systemd/system/bt-auto-connect.service

sudo systemctl daemon-reload
sudo systemctl enable bt-auto-connect
```

## Usage

### Spotify
1. Open Spotify on your phone, tablet, or laptop
2. Tap the "Devices" icon → select **MakeKTM Pi**
3. Play music — audio comes from the C50BT

### Bandcamp
1. Open `http://192.168.1.186:6680/iris` in any browser on your LAN
2. Search for artists/albums on Bandcamp
3. Play tracks — audio comes from the C50BT

To access your **purchased Bandcamp collection** at higher quality:
1. Log in to bandcamp.com in your browser
2. Open DevTools → Application → Cookies → bandcamp.com
3. Copy the value of the `identity` cookie
4. Edit `/etc/mopidy/mopidy.conf`, uncomment and set `identity = <your_cookie>`
5. `sudo systemctl restart mopidy`

## Verification Checklist

```bash
systemctl status bluealsa              # Active (running)
systemctl status raspotify             # Active (running)
systemctl status mopidy                # Active (running)
aplay -D btspeaker /usr/share/sounds/alsa/Front_Center.wav   # Audio from C50BT
lpstat -p                              # Print server still works
free -h                                # RAM usage under ~300MB
```

Then test:
- Spotify app → Devices → "MakeKTM Pi" → play → audio from C50BT
- Browser → `http://192.168.1.186:6680/iris` → search Bandcamp → play → audio from C50BT
- `echo "test" | lp` → printer still works

## Known Caveats

- **BlueALSA is single-stream** — only one app can output to the C50BT at a time. If Mopidy is playing, Raspotify can't simultaneously use the speaker (and vice versa). Not an issue in practice.
- **Raspotify systemd sandboxing** — blocks `AF_BLUETOOTH` by default. The override file (`raspotify-override.conf`) fixes this. Without it you get "PCM not found" errors.
- **Mopidy-Bandcamp is fragile** — it scrapes Bandcamp (no official API). May break if Bandcamp changes their site. Community-maintained.
- **Free Bandcamp streams are 128kbps** — only purchased tracks play at higher quality (mp3-v0) with cookie auth.
- **Pi Zero 2 W BT is 4.2** — supports A2DP/SBC codec. Fine for casual listening, not audiophile-grade. The C50BT is a portable speaker so this is a non-issue.
- **Buffer underruns** — the Pi Zero 2 W's Cortex-A53 is weak. If audio is choppy under load, set CPU governor to performance: `echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor`
- **BT disconnect recovery** — Mopidy and Raspotify don't gracefully recover when the C50BT disconnects mid-stream. Restart the service after reconnecting: `sudo systemctl restart mopidy` or `sudo systemctl restart raspotify`.
- **Two interfaces** — Spotify is controlled from the Spotify app (cast), Bandcamp from the Iris web UI. No unified interface, but both output to the same speaker.
- **Spotify requires Premium** — free tier does not support Spotify Connect.

## Troubleshooting

### Bluetooth adapter won't power on
```bash
# Check if RF-killed
sudo rfkill list
# If "Soft blocked: yes":
sudo rfkill unblock bluetooth
sudo hciconfig hci0 up
```

### "PCM not found" when playing audio
BlueALSA doesn't see the C50BT's A2DP transport. Usually means the speaker connected before BlueALSA started, or BlueALSA was restarted after connecting.
```bash
# Disconnect and reconnect
bluetoothctl disconnect AE:EC:81:96:06:B7
sleep 2
bluetoothctl connect AE:EC:81:96:06:B7

# Verify the PCM is registered
bluealsa-aplay -l
# Should show: AE:EC:81:96:06:B7 [C50BT] ... A2DP (SBC)
```

### C50BT not showing up in Bluetooth scan
- Make sure it's in **pairing mode** (not just powered on) — hold the Bluetooth button until LED flashes rapidly
- If it was previously paired to another device (e.g. laptop), unpair it there first
- The C50BT may take 10-20 seconds to appear in the scan

### Raspotify can't output to Bluetooth
Raspotify's systemd sandboxing blocks Bluetooth sockets by default.
```bash
# Check if the override is installed
cat /etc/systemd/system/raspotify.service.d/override.conf
# Should contain: RestrictAddressFamilies=... AF_BLUETOOTH

# If missing, install it
sudo mkdir -p /etc/systemd/system/raspotify.service.d
sudo cp /home/pi/music-server/raspotify-override.conf /etc/systemd/system/raspotify.service.d/override.conf
sudo systemctl daemon-reload
sudo systemctl restart raspotify
```

### Mopidy can't access BlueALSA
The `mopidy` user needs to be in the `bluetooth` group.
```bash
sudo usermod -aG bluetooth mopidy
sudo systemctl restart mopidy
```

### Audio is choppy / buffer underruns
The Pi Zero 2 W is weak. Reduce CPU contention:
```bash
# Set CPU governor to performance
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# Check RAM pressure
free -h
# If swap is being used heavily, consider stopping unused services
```

### C50BT doesn't auto-connect on boot
```bash
# Check the bt-auto-connect service
systemctl status bt-auto-connect

# Make sure the speaker is trusted (enables auto-reconnect)
bluetoothctl trust AE:EC:81:96:06:B7

# Make sure the MAC address is correct in the service file
cat /etc/systemd/system/bt-auto-connect.service | grep connect

# The speaker must be powered on before the Pi boots (or within the retry window)
# Manual reconnect if needed:
bluetoothctl connect AE:EC:81:96:06:B7
```

### Spotify app doesn't show "MakeKTM Pi"
```bash
# Check Raspotify is running
systemctl status raspotify

# Check logs for errors
journalctl -u raspotify --no-pager -n 30

# Make sure your phone/laptop is on the same WiFi network as the Pi (192.168.1.x)
```

### Iris web UI not loading
```bash
# Check Mopidy is running
systemctl status mopidy

# Check logs
journalctl -u mopidy --no-pager -n 30

# Verify it's listening on port 6680
ss -tlnp | grep 6680
```

### Need to start fresh
```bash
# Stop all music services
sudo systemctl stop raspotify mopidy bt-auto-connect

# Unpair the speaker
bluetoothctl remove AE:EC:81:96:06:B7

# Re-run setup
sudo bash /home/pi/music-server/setup.sh
# Then re-pair the speaker manually
```

## Config Files

All config files are in the `music-server/` directory:

| File | Destination on Pi |
|------|-------------------|
| `asound.conf` | `/etc/asound.conf` |
| `mopidy.conf` | `/etc/mopidy/mopidy.conf` |
| `raspotify.conf` | `/etc/raspotify/conf` |
| `raspotify-override.conf` | `/etc/systemd/system/raspotify.service.d/override.conf` |
| `bt-auto-connect.service` | `/etc/systemd/system/bt-auto-connect.service` |
| `setup.sh` | Run once with `sudo bash setup.sh` |
