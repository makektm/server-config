#!/bin/bash
# NetworkManager dispatcher script: prefer ethernet over WiFi
# When eth0 comes up, disable WiFi. When eth0 goes down, re-enable WiFi.
# Install to: /etc/NetworkManager/dispatcher.d/99-prefer-ethernet

IFACE="$1"
ACTION="$2"

if [ "$IFACE" != "eth0" ]; then
    exit 0
fi

case "$ACTION" in
    up)
        logger "prefer-ethernet: eth0 up — disabling WiFi"
        nmcli radio wifi off
        ;;
    down)
        logger "prefer-ethernet: eth0 down — re-enabling WiFi"
        nmcli radio wifi on
        ;;
esac
