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
| Network | USB ethernet (192.168.1.186), Realtek USB 10/100/1000 via `cdc_ether` |

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
Mopidy (GStreamer)     ──→ queue2 (5MB buffer) ──→ ALSA "btvolume" (softvol) ──→ "btspeaker" ──→ BlueALSA ──→ C50BT
```

Mopidy uses a `queue2` buffer and a `softvol` ALSA plugin (`btvolume`) for volume control. The softvol sits after the buffer, so volume changes are instant.

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
- **softvol lazy initialization** — the `BTVolume` ALSA mixer control is created by `softvol` only when audio first plays through `btvolume`. If Mopidy starts before this, the volume slider won't appear in Iris. Fix: `aplay -D btvolume /usr/share/sounds/alsa/Front_Center.wav` then restart Mopidy. The setup script handles this automatically.
- **Mopidy disables failed extensions for the whole session** — when `Mopidy-ALSAMixer` can't find `BTVolume` at startup, Mopidy logs `Mixer (AlsaMixer) initialization error` and *permanently* disables the extension (falls back to `mixer = software`). The control reappearing later does NOT recover it — only `systemctl restart mopidy` does. This makes the softvol init race especially painful: one missed boot and the Iris volume slider is gone until the next manual restart.
- **Boot race: bluealsa post-hook can start Mopidy too early** — `bluealsa-override.conf`'s `ExecStartPost` runs `systemctl try-restart mopidy` (was `restart` until Nov 2026 — `restart` would START Mopidy at boot before `bt-softvol-init` had a chance to create `BTVolume`, triggering the disabled-extension trap above). `try-restart` is a no-op when Mopidy isn't yet active, so boot ordering (`mopidy.service After=bt-softvol-init.service`) takes over. The post-hook still bounces Mopidy on runtime BlueALSA restarts, which is its actual purpose.
- **BlueALSA keep-alive** — without `--keep-alive`, BlueALSA tears down the A2DP transport the instant the last PCM client disconnects (even between tracks). This causes `GStreamer error: Internal data stream error` in Mopidy and cascading WebSocket failures in Iris ("pusher is not connected"). The `bluealsa-override.conf` sets `--keep-alive=30` (seconds). After pausing audio, the BT transport stays open for 30 seconds — resuming within that window is instant. Resuming after 30+ seconds requires A2DP renegotiation (~4 second delay before audio starts).
- **Mopidy-Bandcamp pydantic UUID crash** — Bandcamp returns artists with an empty `musicbrainz_id`. pydantic v2 (used by Mopidy 4.x) rejects `""` as an invalid UUID, causing a `ValidationError` that drops the active audio stream. `setup.sh` patches `library.py` in-place replacing `musicbrainz_id=""` with `musicbrainz_id=None`. Re-apply the patch after upgrading `Mopidy-Bandcamp`.
- **BT disconnect recovery** — Mopidy and Raspotify don't gracefully recover when the C50BT fully disconnects mid-stream. Restart the service after reconnecting: `sudo systemctl restart mopidy` or `sudo systemctl restart raspotify`.
- **Mopidy pipeline watchdog** — `mopidy-pipeline-watchdog.service` tails the Mopidy journal and, on any `GStreamer error` (broadened from the original `Internal data stream error`-only match — see `bluealsa-override.conf` history), issues an RPC `core.playback.stop` then `core.playback.play` to rebuild the gstreamer pipeline; the 3rd strike in a 5-minute window escalates to `systemctl restart mopidy`. Without this, playback state stays `"playing"` but no audio reaches the speaker until manual intervention. Logs to syslog with tag `mopidy-watchdog`.
- **Silent pipeline hang (no GStreamer error logged at all)** — sometimes `alsasink`'s blocking ALSA write to the BlueALSA-backed `btvolume` device just hangs — seen right after BlueALSA's IO thread pauses/resumes between tracks — without GStreamer ever posting a bus error. State stays `"playing"`, position freezes at whatever it was, and the log watchdog above never fires because there's no `GStreamer error` line to match. Fixed (2026-07-06) by inserting GStreamer's own `watchdog` element into the output pipeline: `output = queue2 ... ! watchdog timeout=20000 ! alsasink device=btvolume` in `mopidy.conf`. It posts a real bus error after 20s of no dataflow, which the existing log-based watchdog above then catches and recovers from — no new polling script needed. Requires `gstreamer1.0-plugins-bad` (`setup.sh` installs it with `--no-install-recommends` to skip ~40 unrelated codec/GUI deps).
- **Do not remove `gst-plugin-spotify`** — despite the name looking unrelated to anything in this repo's tracked configs, it provides the `spotifyaudiosrc` GStreamer element that Mopidy's audio backend uses to actually stream `spotify:track:...` URIs (this is how Spotify tracks play *through Iris*, separate from Raspotify/Spotify-Connect). It's not in any apt repo — `setup.sh` downloads a prebuilt armhf `.deb` from `kingosticks/gst-plugins-rs-build` on GitHub and installs it with `dpkg --force-depends` (its declared dep `libglib2.0-0` was renamed to `libglib2.0-0t64` in Trixie, and no repo carries a package under that name anymore). If it's ever removed, playback fails with `GStreamer error: No URI handler implemented for "spotify"` and there is no other way to recover it except re-running that same download step from `setup.sh`.
- **Restarting BlueALSA drops BT + causes Mopidy/Raspotify conflict** — `systemctl restart bluealsa` disconnects the C50BT. Mopidy's GStreamer pipeline then enters an error loop repeatedly trying to grab the BlueALSA device, which fights with Raspotify (both can't hold the single-stream PCM). After any BlueALSA restart, always run: `bluetoothctl connect AE:EC:81:96:06:B7 && sudo systemctl restart mopidy`.
- **Two interfaces** — Spotify is controlled from the Spotify app (cast), Bandcamp from the Iris web UI. No unified interface, but both output to the same speaker.
- **Spotify requires Premium** — free tier does not support Spotify Connect.
- **Boot race: Mopidy-Spotify OAuth login never retries after failing once** — `network-online.target` reporting active doesn't guarantee DNS/routing is actually usable yet. If Mopidy starts before the network is truly ready, `mopidy_spotify.web`'s token fetch exhausts its 0.5/1/2s retry backoff, logs `OAuth token refresh failed: Unknown error`, and gives up — permanently, for that process's whole lifetime. Every subsequent search/browse/add-to-queue then fails silently with `mopidy_spotify.lookup Not logged in` in the log (Iris shows "Failed to add some tracks"), even though the credentials and network are fine — a fresh Mopidy process re-authenticates in ~2 seconds. `mopidy-spotify-login-watchdog.service` watches for this pattern (2 strikes in a 10-minute window) and runs `systemctl restart mopidy` automatically, same tiered approach as the pipeline watchdog. (2026-08-20)
- **Iris system actions need a sudoers rule that isn't installed by pip** — the "Restart Mopidy" / "Upgrade Iris" / "Local scan" buttons in the Iris UI shell out to `mopidy_iris/system.sh` via `sudo`, which fails with `Password-less access to .../system.sh was refused` unless `/etc/sudoers.d/mopidy-iris` grants the `mopidy` user a NOPASSWD rule for that exact script. Neither `pip install mopidy-iris` nor Mopidy itself sets this up — `setup.sh` now installs `mopidy-iris-sudoers` for it. Without it, restarting Mopidy always requires SSH.

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

### Iris volume slider missing
The `Mopidy-ALSAMixer` extension failed to find `BTVolume` at startup and Mopidy disabled it for the session. Diagnose:
```bash
# Mopidy mixer state — null means no mixer is loaded
curl -s -X POST http://127.0.0.1:6680/mopidy/rpc \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"core.mixer.get_volume"}'
# {"result":null}  → broken
# {"result":42}    → working

# Confirm the ALSA control exists now
amixer -c 0 sget BTVolume
# Should print "Simple mixer control 'BTVolume',0 ..."

# Look for the disabled-extension log line
sudo journalctl -u mopidy -b | grep -i 'Mixer (AlsaMixer) initialization error'
```
Quick fix — restart Mopidy now that the control exists:
```bash
sudo systemctl restart mopidy
```
Permanent fix — make sure `bt-softvol-init.service` actually succeeds at boot. Symptoms of failure: `systemctl status bt-softvol-init` shows `inactive (dead)` with `Dependency failed` or a non-zero exit. Causes: BlueALSA restarted between init and Mopidy start (the `bluealsa-override.conf` `ExecStartPost` used to call `systemctl restart mopidy`, which started Mopidy too early — fixed by switching to `try-restart`). Re-deploy the latest `bluealsa-override.conf` and `bt-softvol-init.service` from this repo.

### Iris web UI not loading
```bash
# Check Mopidy is running
systemctl status mopidy

# Check logs
journalctl -u mopidy --no-pager -n 30

# Verify it's listening on port 6680
ss -tlnp | grep 6680
```

### "Mopidy: Failed to add some tracks" in Iris (Spotify)
Mopidy-Spotify's OAuth login failed once (usually right after boot, from a network race) and never retried — it's been silently rejecting every lookup since. Diagnose:
```bash
# Look for the stuck-login signature
sudo journalctl -u mopidy --since "15 min ago" | grep -i "not logged in\|oauth token refresh failed"

# Confirm: does a fresh process log in fine? (proves creds/network are OK)
sudo -u mopidy timeout 10 /usr/local/bin/mopidy \
  --config /usr/share/mopidy/conf.d:/etc/mopidy/conf.d:/etc/mopidy/mopidy.conf -v 2>&1 \
  | grep -i "logged into spotify"
```
Fix — restart Mopidy:
```bash
sudo systemctl restart mopidy
```
`mopidy-spotify-login-watchdog.service` does this automatically now (2 strikes in 10 minutes). If it's not installed/enabled yet, re-run `setup.sh` or copy `mopidy-spotify-login-watchdog.sh`/`.service` from this repo manually.

### One-shot status check
Instead of running the above commands by hand one at a time:
```bash
/usr/local/bin/music-server-healthcheck
# or, from this repo without deploying it first:
ssh pi@192.168.1.186 bash -s < music-server/healthcheck.sh
```
Reports service status, memory/disk/throttling, Bluetooth connection, cache sizes, a live Spotify auth probe, and a scan for known error patterns in the last 15 minutes. Exits non-zero if anything failed.

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
| `bluealsa-override.conf` | `/etc/systemd/system/bluealsa.service.d/override.conf` |
| `bt-auto-connect.service` | `/etc/systemd/system/bt-auto-connect.service` |
| `bt-softvol-init.service` | `/etc/systemd/system/bt-softvol-init.service` |
| `mopidy_bandcamp_cache.py` | `<mopidy_bandcamp pkg dir>/_cache.py` |
| `mopidy-pipeline-watchdog.sh` | `/usr/local/bin/mopidy-pipeline-watchdog.sh` |
| `mopidy-pipeline-watchdog.service` | `/etc/systemd/system/mopidy-pipeline-watchdog.service` |
| `mopidy-spotify-login-watchdog.sh` | `/usr/local/bin/mopidy-spotify-login-watchdog.sh` |
| `mopidy-spotify-login-watchdog.service` | `/etc/systemd/system/mopidy-spotify-login-watchdog.service` |
| `mopidy-iris-sudoers` | `/etc/sudoers.d/mopidy-iris` |
| `healthcheck.sh` | `/usr/local/bin/music-server-healthcheck` |
| `setup.sh` | Run once with `sudo bash setup.sh` |
