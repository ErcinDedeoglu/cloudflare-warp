#!/bin/bash

# Copyright (c) 2025 Ercin Dedeoglu
# Licensed under CC BY-NC 4.0 (Attribution-NonCommercial)
# https://github.com/ErcinDedeoglu/cloudflare-warp
#
# Commercial use is prohibited. For personal/educational use,
# you must provide public attribution to this project.

set -e

# start dbus
sudo mkdir -p /run/dbus
if [ -f /run/dbus/pid ]; then
    sudo rm /run/dbus/pid
fi
sudo dbus-daemon --config-file=/usr/share/dbus-1/system.conf

# start the daemon
sudo warp-svc --accept-tos &

# wait for the daemon to be ready
MAX_WAIT=${WARP_CONNECT_TIMEOUT:-30}
INTERVAL=2
ELAPSED=0

echo "Waiting for WARP daemon to be ready (max ${MAX_WAIT}s)..."
while [ $ELAPSED -lt $MAX_WAIT ]; do
    if warp-cli status 2>/dev/null | grep -qE "(Status|Connected)"; then
        echo "WARP daemon is ready after ${ELAPSED}s"
        break
    fi
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
    echo "Warning: WARP daemon may not be fully ready after ${MAX_WAIT}s, continuing anyway..."
fi

# register if needed
if [ ! -f /var/lib/cloudflare-warp/reg.json ]; then
    warp-cli registration new && echo "Warp client registered!"
    if [ -n "$WARP_LICENSE_KEY" ]; then
        echo "License key found, registering license..."
        warp-cli registration license "$WARP_LICENSE_KEY" > /dev/null 2>&1 && echo "Warp license registered!" || echo "Failed to register license"
    fi
fi

# set proxy mode and connect
warp-cli --accept-tos mode proxy
warp-cli --accept-tos connect
echo "WARP proxy mode active on localhost:40000"

# disable qlog
if [ -z "$DEBUG_ENABLE_QLOG" ]; then
    warp-cli --accept-tos debug qlog disable
fi

# Build GOST arguments
GOST_LISTEN=":1080"
GOST_OPTS=""

if [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
    GOST_LISTEN="${PROXY_USER}:${PROXY_PASS}@:1080"
    echo "Proxy authentication enabled for user: ${PROXY_USER}"
fi

CLIMITER=${PROXY_MAX_CONN:-10}
RLIMITER=${PROXY_MAX_RPS:-10}
GOST_OPTS="climiter=${CLIMITER}&rlimiter=${RLIMITER}"

if [ -n "$PROXY_ALLOWED_IPS" ]; then
    GOST_OPTS="${GOST_OPTS}&admission=~${PROXY_ALLOWED_IPS}"
    echo "IP whitelist enabled: ${PROXY_ALLOWED_IPS}"
fi

# Chain GOST to WARP proxy
GOST_ARGS="-L socks5://${GOST_LISTEN}?${GOST_OPTS} -F socks5://127.0.0.1:40000"

echo "Starting GOST proxy on :1080 -> WARP proxy"
gost $GOST_ARGS
