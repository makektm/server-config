# RPi Zero 2 W — Canon LBP2900 Network Print Server

## Problem

The Canon LBP2900 is a USB-only laser printer with no network capability. It uses Canon's proprietary CAPT (Canon Advanced Printing Technology) protocol, which means standard PCL/PostScript drivers don't work. The goal is to share it on the LAN so any Windows machine can print to it via Ctrl+P — without cloud services or SaaS dependencies.

## Why This Approach

### PrinterCow (rejected)
Originally considered PrinterCow, but it pivoted to SaaS-only. We need a fully local, self-hosted solution.

### captdriver + CUPS + Samba on RPi Zero 2 W (chosen)
- **captdriver** is an open-source reverse-engineered CAPT driver. It has been confirmed working on ARMv7 Raspberry Pi with the LBP2900 specifically.
- **CUPS** handles print queue management and the raster-to-CAPT conversion pipeline.
- **Samba** exposes the CUPS printer as a Windows-compatible SMB share, so Windows clients can discover and print without installing any special drivers.
- **RPi Zero 2 W** is cheap, low-power, has WiFi built in, and a USB port for the printer. It runs headless with no maintenance.

### Why not Canon's official driver?
Canon only provides x86 Linux binaries (if at all). No ARM support. captdriver is the only option for ARM-based hardware.

## Hardware

| Component | Details |
|-----------|---------|
| Print server | Raspberry Pi Zero 2 W |
| Printer | Canon LBP2900 (USB) |
| Connection | USB-B cable + micro USB OTG adapter (Pi has micro USB data port) |
| Network | WiFi (192.168.1.186) |

## Software Stack

| Component | Role |
|-----------|------|
| Raspbian 13 (trixie), 32-bit ARMv7 | OS — 32-bit chosen because captdriver is confirmed on ARMv7 |
| [captdriver](https://github.com/mounaiban/captdriver) | Open-source CAPT protocol driver |
| CUPS | Print server / spooler |
| Samba | SMB printer sharing for Windows clients |
| Avahi | mDNS/DNS-SD for network discovery |

## Setup Steps

### 1. Flash the RPi

Flash Raspberry Pi OS Lite (32-bit) to SD card. Enable SSH and WiFi during imaging (via Raspberry Pi Imager advanced settings or by placing `ssh` file and `wpa_supplicant.conf` in boot partition).

### 2. Install dependencies

```bash
sudo apt update && sudo apt install -y \
  build-essential automake libcups2-dev git \
  cups samba avahi-daemon
sudo usermod -aG lpadmin pi
```

### 3. Build captdriver

```bash
cd /home/pi
git clone https://github.com/mounaiban/captdriver.git
cd captdriver
aclocal && autoconf && automake --add-missing
./configure && make && make ppd
```

Verify: `src/rastertocapt` binary exists, `ppd/` directory contains PPD files (notably `CanonLBP-2900-3000.ppd`).

### 4. Install captdriver into CUPS

```bash
sudo make install
sudo cp -p /usr/local/bin/rastertocapt $(cups-config --serverbin)/filter/
```

This places the `rastertocapt` filter where CUPS expects it (typically `/usr/lib/cups/filter/`).

### 5. Enable CUPS remote access and sharing

```bash
sudo cupsctl --remote-admin --share-printers
sudo systemctl restart cups
```

### 6. Configure Samba

Edit `/etc/samba/smb.conf` — update the `[printers]` and `[print$]` sections, and add an explicit `[LBP2900]` share (CUPS 2.4+ on Debian trixie doesn't generate `/etc/printcap`, so the auto `[printers]` share won't discover CUPS printers — the explicit share is required):

```ini
[printers]
   comment = All Printers
   browseable = yes
   path = /var/spool/samba
   printable = yes
   guest ok = yes
   read only = yes
   create mask = 0700

[print$]
   comment = Printer Drivers
   path = /var/lib/samba/printers
   browseable = yes
   read only = yes
   guest ok = yes

[LBP2900]
   comment = Canon LBP2900
   path = /var/spool/samba
   printable = yes
   guest ok = yes
   read only = yes
   create mask = 0700
   printing = cups
   use client driver = yes
```

Then:

```bash
sudo mkdir -p /var/spool/samba && sudo chmod 1777 /var/spool/samba
sudo systemctl restart smbd
```

### 7. Add the printer

Connect the LBP2900 via USB-B cable + micro USB OTG adapter into the Pi's **data port** (the micro USB port closer to the HDMI, labelled "USB" — not "PWR"). Then:

```bash
# Find the printer URI
sudo /usr/sbin/lpinfo -v | grep Canon

# Add it (substitute the URI from lpinfo output)
sudo lpadmin -p 'LBP2900' \
  -v 'usb://Canon/LBP2900?serial=0000A364P41S' \
  -P /home/pi/captdriver/ppd/CanonLBP-2900-3000.ppd \
  -L 'Office' -E

# Set as default
sudo lpadmin -d 'LBP2900'

# Restart Samba so it picks up the new printer
sudo systemctl restart smbd
```

Note: `lpinfo` is in `/usr/sbin/` which may not be in `$PATH` — use the full path or sudo.

### 8. Connect from Linux

No Samba needed — Linux clients talk directly to the Pi's CUPS server via IPP.

```bash
sudo lpadmin -p 'LBP2900' \
  -v 'ipp://192.168.1.186/printers/LBP2900' \
  -E

# Optional: set as default
sudo lpadmin -d 'LBP2900'

# Test
echo "test" | lp
```

**Important:** Do NOT use the Avahi/mDNS auto-discovered printer. CUPS will create an `implicitclass://` backend that causes a broken pipe retry loop (`cfFilterPDFToPDF: Broken pipe` → `universal filter failed`). Always add the printer manually with the explicit `ipp://` URI as shown above.

### 9. Connect from Windows

Settings > Printers > Add Printer. It should auto-discover via Samba/Avahi. If not, manually add: `\\192.168.1.186\LBP2900`

## Verification Checklist

```bash
lpstat -p                        # Printer shows as idle
echo "test" | lp                 # Test print from the Pi
smbclient -L //192.168.1.186    # Shared printer visible
```

Then test print from a Windows machine.

## Known Caveats

- **captdriver is alpha-quality** — multi-page jobs may have long delays between pages.
- **USB `error -71` (EPROTO)** — if `dmesg` shows `device descriptor read/64, error -71`, it's a cable/adapter issue, not a power issue. Swap the USB cable — a bad cable was the cause during initial setup.
- **OTG adapter quality matters** — cheap micro USB OTG adapters can cause enumeration failures. Use a known-good one.
- **CUPS-libusb quirks** — if the printer isn't detected, check `lsusb` and try unplugging/replugging.
- **64-bit vs 32-bit** — if you ever rebuild with 64-bit RPi OS and captdriver fails to compile or run, fall back to 32-bit (ARMv7). That's the tested configuration.
- **No duplex** — the LBP2900 is simplex only, captdriver doesn't change that.
- **CUPS PPD deprecation warning** — `lpadmin` warns that printer drivers are deprecated in future CUPS versions. Not a concern — the LBP2900 will never support driverless IPP, and captdriver+PPD will keep working. Worst case, pin the CUPS version.
- **`implicitclass://` on Linux clients** — if a Linux client auto-discovers the printer via Avahi, CUPS may create an `implicitclass://` backend instead of a direct IPP connection. This causes `cfFilterPDFToPDF: Broken pipe` errors in a retry loop. Fix: `sudo lpadmin -p LBP2900 -v 'ipp://192.168.1.186/printers/LBP2900' -E` to force the direct IPP URI.
- **"bad reply from printer" after power cycle** — after restarting the LBP2900, captdriver may report `CAPT: bad reply from printer, expected A0 E0 xx xx xx xx, got` (empty). The printer needs ~30 seconds to warm up before it can accept CAPT commands. Wait, then restart the job: `sudo lp -i <job-id> -H restart`.

## Current Status (2026-03-26)

Steps 1-8 are complete. Printer is online at `192.168.1.186`, printing from the Pi and Linux clients works via direct IPP (`ipp://192.168.1.186/printers/LBP2900`). Step 9 (Windows client setup) is pending — just needs someone to Add Printer → `\\192.168.1.186\LBP2900` from a Windows machine.
