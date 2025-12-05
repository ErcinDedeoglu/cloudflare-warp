#!/bin/bash

# Copyright (c) 2025 Ercin Dedeoglu
# Licensed under CC BY-NC 4.0 (Attribution-NonCommercial)
# https://github.com/ErcinDedeoglu/cloudflare-warp
#
# Commercial use is prohibited. For personal/educational use,
# you must provide public attribution to this project.

# exit when any command fails
set -e

# create a tun device if not exist
# allow passing device to ensure compatibility with Podman
if [ ! -e /dev/net/tun ]; then
    sudo mkdir -p /dev/net
    sudo mknod /dev/net/tun c 10 200
    sudo chmod 600 /dev/net/tun
fi

# start dbus
sudo mkdir -p /run/dbus
if [ -f /run/dbus/pid ]; then
    sudo rm /run/dbus/pid
fi
sudo dbus-daemon --config-file=/usr/share/dbus-1/system.conf

# start the daemon
sudo warp-svc --accept-tos &

# wait for the daemon to be ready (smart retry with configurable timeout)
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

# if /var/lib/cloudflare-warp/reg.json not exists, setup new warp client
if [ ! -f /var/lib/cloudflare-warp/reg.json ]; then
    # if /var/lib/cloudflare-warp/mdm.xml not exists or REGISTER_WHEN_MDM_EXISTS not empty, register the warp client
    if [ ! -f /var/lib/cloudflare-warp/mdm.xml ] || [ -n "$REGISTER_WHEN_MDM_EXISTS" ]; then
        warp-cli registration new && echo "Warp client registered!"
        # if a license key is provided, register the license
        if [ -n "$WARP_LICENSE_KEY" ]; then
            echo "License key found, registering license..."
            # Mask output to prevent license key leakage in logs
            warp-cli registration license "$WARP_LICENSE_KEY" > /dev/null 2>&1 && echo "Warp license registered!" || echo "Failed to register license"
        fi
    fi
    # connect to the warp server
    warp-cli --accept-tos connect
else
    echo "Warp client already registered, skip registration"
fi

# disable qlog if DEBUG_ENABLE_QLOG is empty
if [ -z "$DEBUG_ENABLE_QLOG" ]; then
    warp-cli --accept-tos debug qlog disable
else
    warp-cli --accept-tos debug qlog enable
fi

# if WARP_ENABLE_NAT is provided, enable NAT and forwarding
if [ -n "$WARP_ENABLE_NAT" ]; then
    # switch to warp mode
    echo "[NAT] Switching to warp mode..."
    warp-cli --accept-tos mode warp
    warp-cli --accept-tos connect

    # wait for the daemon to reconfigure (smart retry)
    echo "[NAT] Waiting for WARP to reconfigure..."
    NAT_WAIT=0
    NAT_TIMEOUT=${WARP_CONNECT_TIMEOUT:-30}
    while [ $NAT_WAIT -lt $NAT_TIMEOUT ]; do
        if warp-cli status 2>/dev/null | grep -q "Connected"; then
            echo "[NAT] WARP reconfigured after ${NAT_WAIT}s"
            break
        fi
        sleep 2
        NAT_WAIT=$((NAT_WAIT + 2))
    done

    # enable NAT
    echo "[NAT] Enabling NAT..."
    sudo nft add table ip nat
    sudo nft add chain ip nat WARP_NAT { type nat hook postrouting priority 100 \; }
    sudo nft add rule ip nat WARP_NAT oifname "CloudflareWARP" masquerade
    sudo nft add table ip mangle
    sudo nft add chain ip mangle forward { type filter hook forward priority mangle \; }
    sudo nft add rule ip mangle forward tcp flags syn tcp option maxseg size set rt mtu

    sudo nft add table ip6 nat
    sudo nft add chain ip6 nat WARP_NAT { type nat hook postrouting priority 100 \; }
    sudo nft add rule ip6 nat WARP_NAT oifname "CloudflareWARP" masquerade
    sudo nft add table ip6 mangle
    sudo nft add chain ip6 mangle forward { type filter hook forward priority mangle \; }
    sudo nft add rule ip6 mangle forward tcp flags syn tcp option maxseg size set rt mtu
fi

# Auth failure tracking configuration
# Default: Ban for 300 seconds (5 min) after 5 failed auth attempts
AUTH_FAIL_LIMIT=${PROXY_AUTH_FAIL_LIMIT:-5}
AUTH_BAN_TIME=${PROXY_AUTH_BAN_TIME:-300}
AUTH_FAIL_WINDOW=${PROXY_AUTH_FAIL_WINDOW:-60}
AUTH_FAIL_STORE="/tmp/auth_failures"

# Auth failure monitor function - runs in background
# Parses GOST debug logs and bans IPs after too many auth failures
auth_failure_monitor() {
    mkdir -p "$AUTH_FAIL_STORE"
    
    while read -r line; do
        # GOST v3 logs auth failures in these formats:
        # 1. UserPassResponse "1 1" (version=1, status=1=failure) at INFO level
        # 2. "auth failure" or "ErrAuthFailure" at error level
        # 3. JSON format with "1 1" in msg field
        # The log line includes "remote" field with client IP
        if echo "$line" | grep -qE '("1 1"|auth.*fail|ErrAuthFailure|"status":1)'; then
            # Extract IP address from log line (handles both plain and JSON format)
            # Look for "remote":"IP:port" or just IP in the line
            IP=$(echo "$line" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
            
            if [ -n "$IP" ]; then
                # Check if IP is already banned
                if sudo iptables -C INPUT -s "$IP" -p tcp --dport 1080 -j DROP 2>/dev/null; then
                    continue
                fi
                
                # Track failure with timestamp
                FAIL_FILE="${AUTH_FAIL_STORE}/${IP}"
                NOW=$(date +%s)
                
                # Add current failure
                echo "$NOW" >> "$FAIL_FILE"
                
                # Remove old entries (outside the window)
                WINDOW_START=$((NOW - AUTH_FAIL_WINDOW))
                if [ -f "$FAIL_FILE" ]; then
                    awk -v ws="$WINDOW_START" '$1 >= ws' "$FAIL_FILE" > "${FAIL_FILE}.tmp" && mv "${FAIL_FILE}.tmp" "$FAIL_FILE"
                fi
                
                # Count recent failures
                FAIL_COUNT=$(wc -l < "$FAIL_FILE" 2>/dev/null || echo 0)
                
                echo "[AUTH] Failed auth from $IP (${FAIL_COUNT}/${AUTH_FAIL_LIMIT} in ${AUTH_FAIL_WINDOW}s window)"
                
                # Ban if exceeded limit
                if [ "$FAIL_COUNT" -ge "$AUTH_FAIL_LIMIT" ]; then
                    echo "[AUTH] BANNING $IP for ${AUTH_BAN_TIME}s (${FAIL_COUNT} failed attempts)"
                    sudo iptables -I INPUT -s "$IP" -p tcp --dport 1080 -j DROP
                    
                    # Schedule unban
                    (
                        sleep "$AUTH_BAN_TIME"
                        sudo iptables -D INPUT -s "$IP" -p tcp --dport 1080 -j DROP 2>/dev/null
                        rm -f "$FAIL_FILE"
                        echo "[AUTH] UNBANNED $IP after ${AUTH_BAN_TIME}s"
                    ) &
                    
                    # Clear failure counter
                    rm -f "$FAIL_FILE"
                fi
            fi
        fi
    done
}

if [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
    echo "Auth failure protection enabled: Ban for ${AUTH_BAN_TIME}s after ${AUTH_FAIL_LIMIT} failures in ${AUTH_FAIL_WINDOW}s"
fi

# Remove restrictive iptables rules to allow external proxy access (default behavior)
# Some environments (Docker with NET_ADMIN, warp-svc) may add DROP rules
# to the raw PREROUTING chain that block external access to the proxy
# Set RESTRICT_EXTERNAL_PROXY=1 to keep these rules and only allow local/Docker network access
if [ -z "$RESTRICT_EXTERNAL_PROXY" ]; then
    echo "[EXTERNAL] Removing restrictive firewall rules to allow external proxy access..."
    # Remove any DROP rules in raw PREROUTING that target port 1080
    # These rules block external traffic before NAT can process it
    while sudo iptables -t raw -D PREROUTING -p tcp --dport 1080 -j DROP 2>/dev/null; do
        echo "[EXTERNAL] Removed a DROP rule from raw PREROUTING"
    done
    # Also try to remove rules with interface conditions
    for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -E '^br-'); do
        sudo iptables -t raw -D PREROUTING -p tcp ! -i "$iface" --dport 1080 -j DROP 2>/dev/null && \
            echo "[EXTERNAL] Removed DROP rule for interface $iface"
    done
    # Remove nftables rules if nft is available
    if command -v nft &> /dev/null; then
        # List and remove any drop rules targeting port 1080 in raw table
        sudo nft list table ip raw 2>/dev/null | grep -q "tcp dport 1080.*drop" && \
            sudo nft flush chain ip raw PREROUTING 2>/dev/null && \
            echo "[EXTERNAL] Flushed nftables raw PREROUTING chain"
    fi
    echo "[EXTERNAL] External proxy access enabled"
else
    echo "[EXTERNAL] RESTRICT_EXTERNAL_PROXY is set - keeping firewall rules (local/Docker network access only)"
fi

# Build GOST arguments with optional authentication and rate limiting
GOST_LISTEN=":1080"
GOST_OPTS=""

# Add authentication if both user and password are provided
if [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
    GOST_LISTEN="${PROXY_USER}:${PROXY_PASS}@:1080"
    echo "Proxy authentication enabled for user: ${PROXY_USER}"
fi

# Add GOST-level rate limiting options
# climiter: max concurrent connections per IP (default: 10)
# rlimiter: max requests per second per IP (default: 10)
CLIMITER=${PROXY_MAX_CONN:-10}
RLIMITER=${PROXY_MAX_RPS:-10}
GOST_OPTS="climiter=${CLIMITER}&rlimiter=${RLIMITER}"
echo "GOST rate limiting: max ${CLIMITER} concurrent connections, ${RLIMITER} requests/sec per IP"

# Add IP whitelist if provided (admission control)
# Format: comma-separated IPs or CIDRs, e.g., "192.168.1.0/24,10.0.0.0/8"
if [ -n "$PROXY_ALLOWED_IPS" ]; then
    # Use ~ prefix for whitelist mode in GOST
    GOST_OPTS="${GOST_OPTS}&admission=~${PROXY_ALLOWED_IPS}"
    echo "IP whitelist enabled: only allowing connections from ${PROXY_ALLOWED_IPS}"
fi

# Construct final GOST_ARGS
GOST_ARGS="-L socks5://${GOST_LISTEN}?${GOST_OPTS}"

# start the proxy
# If auth is enabled, run with debug logging and monitor for auth failures
if [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
    echo "Starting GOST with authentication failure monitoring..."
    # Run GOST with debug logging, tee output to both console and auth monitor
    gost $GOST_ARGS -D 2>&1 | tee >(auth_failure_monitor)
else
    gost $GOST_ARGS
fi
