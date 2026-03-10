#!/bin/bash

# Copyright (c) 2025 Ercin Dedeoglu
# Licensed under CC BY-NC 4.0 (Attribution-NonCommercial)
# https://github.com/ErcinDedeoglu/cloudflare-warp
#
# Commercial use is prohibited. For personal/educational use,
# you must provide public attribution to this project.

set -e

WARP_INSTANCES=${WARP_INSTANCES:-1}

# Validate WARP_INSTANCES
if ! [[ "$WARP_INSTANCES" =~ ^[0-9]+$ ]] || [ "$WARP_INSTANCES" -lt 1 ]; then
    echo "Error: WARP_INSTANCES must be a positive integer"
    exit 1
fi

# ---- Parse license key(s) — WARP_LICENSE_KEY accepts comma-separated values ----
LICENSE_KEYS=()
if [ -n "${WARP_LICENSE_KEY:-}" ]; then
    IFS=',' read -ra _RAW_KEYS <<< "$WARP_LICENSE_KEY"
    for _k in "${_RAW_KEYS[@]}"; do
        _k=$(echo "$_k" | xargs)
        [ -n "$_k" ] && LICENSE_KEYS+=("$_k")
    done
fi
NUM_KEYS=${#LICENSE_KEYS[@]}

# Reconstruct cleaned CSV for passing to instance scripts and change detection
LICENSE_KEYS_CSV=""
if [ "$NUM_KEYS" -gt 0 ]; then
    LICENSE_KEYS_CSV=$(IFS=','; echo "${LICENSE_KEYS[*]}")
fi

# ==============================================================================
# SINGLE INSTANCE MODE (default, fully backward-compatible)
# ==============================================================================
if [ "$WARP_INSTANCES" -eq 1 ]; then

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

    # register and apply license (tries all keys in order, stops on first success)
    STORED_KEY_FILE="/var/lib/cloudflare-warp/.license_key"

    apply_license_keys() {
        local label=$1
        for i in $(seq 0 $((NUM_KEYS - 1))); do
            local key="${LICENSE_KEYS[$i]}"
            echo "Trying license key $((i + 1))/${NUM_KEYS}..."
            local out
            out=$(warp-cli registration license "$key" 2>&1) && {
                echo "Warp license ${label} (key $((i + 1)))!"
                echo -n "$LICENSE_KEYS_CSV" | sudo tee "$STORED_KEY_FILE" > /dev/null
                return 0
            } || {
                echo "Key $((i + 1)) failed: ${out}"
            }
        done
        echo "All ${NUM_KEYS} license keys failed, running as free WARP"
        return 1
    }

    if [ ! -f /var/lib/cloudflare-warp/reg.json ]; then
        warp-cli registration new && echo "Warp client registered!"
        if [ "$NUM_KEYS" -gt 0 ]; then
            apply_license_keys "registered" || true
        fi
    else
        # Re-apply license if keys have changed since last registration
        STORED_KEYS=""
        [ -f "$STORED_KEY_FILE" ] && STORED_KEYS=$(sudo cat "$STORED_KEY_FILE" 2>/dev/null)
        if [ "$NUM_KEYS" -gt 0 ] && [ "$LICENSE_KEYS_CSV" != "$STORED_KEYS" ]; then
            echo "License key(s) changed, re-applying..."
            apply_license_keys "updated" || true
        fi
    fi

    # set proxy mode and connect
    warp-cli --accept-tos mode proxy
    warp-cli --accept-tos connect
    echo "WARP proxy mode active on localhost:40000"

    # disable qlog
    warp-cli --accept-tos debug qlog disable

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

    # Build HTTP proxy listen addresses
    HTTP_WARP_LISTEN=":8080"
    HTTP_DIRECT_LISTEN=":8081"
    if [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
        HTTP_WARP_LISTEN="${PROXY_USER}:${PROXY_PASS}@:8080"
        HTTP_DIRECT_LISTEN="${PROXY_USER}:${PROXY_PASS}@:8081"
    fi

    # Build direct proxy listen address
    DIRECT_LISTEN=":1081"
    if [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
        DIRECT_LISTEN="${PROXY_USER}:${PROXY_PASS}@:1081"
    fi

    # Start direct proxies (SOCKS5 on 1081, HTTP on 8081) - bypass WARP
    echo "Starting direct proxies on :1081 (SOCKS5) and :8081 (HTTP) -> Internet (no WARP)"
    gost -L "socks5://${DIRECT_LISTEN}?${GOST_OPTS}" -L "http://${HTTP_DIRECT_LISTEN}?${GOST_OPTS}" &

    # Start Shadowsocks servers (for mobile VPN clients)
    # Use PROXY_PASS if set, otherwise default to 'cloudflare-warp'
    SS_PASS=${PROXY_PASS:-cloudflare-warp}
    SS_METHOD=${SS_METHOD:-chacha20-ietf-poly1305}

    echo "Starting Shadowsocks servers:"
    echo "  - WARP exit on :8388 (method: ${SS_METHOD})"
    echo "  - Direct exit on :8389 (method: ${SS_METHOD})"

    # Shadowsocks through WARP
    gost -L "ss://${SS_METHOD}:${SS_PASS}@:8388?${GOST_OPTS}" -F socks5://127.0.0.1:40000 &

    # Shadowsocks direct (bypass WARP)
    gost -L "ss://${SS_METHOD}:${SS_PASS}@:8389?${GOST_OPTS}" &

    # Generate connection info for mobile apps
    echo ""
    echo "=== Shadowsocks Connection Info ==="
    echo "For mobile apps (Shadowsocks, Shadowrocket, v2rayNG):"
    echo "  Server: <YOUR_SERVER_IP>"
    echo "  Port (WARP): 8388"
    echo "  Port (Direct): 8389"
    if [ -n "$PROXY_PASS" ]; then
        echo "  Password: <your PROXY_PASS>"
    else
        echo "  Password: cloudflare-warp"
    fi
    echo "  Method: ${SS_METHOD}"
    echo "==================================="
    echo ""

    # Start WARP proxies (SOCKS5 on 1080, HTTP on 8080) - chain to WARP
    echo "Starting WARP proxies on :1080 (SOCKS5) and :8080 (HTTP) -> WARP proxy"
    gost -L "socks5://${GOST_LISTEN}?${GOST_OPTS}" -L "http://${HTTP_WARP_LISTEN}?${GOST_OPTS}" -F socks5://127.0.0.1:40000

    # Unreachable — gost above runs in the foreground
    exit 0
fi

# ==============================================================================
# MULTI-INSTANCE MODE (WARP_INSTANCES > 1)
#
# Each warp-svc uses STATE_DIRECTORY and RUNTIME_DIRECTORY env vars
# (systemd convention) to see its own data dir and IPC socket.
# Each instance gets a unique Cloudflare IP for round-robin rotation.
#
# No extra Docker capabilities required (no SYS_ADMIN).
# ==============================================================================

echo "========================================"
echo " Multi-Instance WARP Mode"
echo " Instances : ${WARP_INSTANCES}"
if [ "$NUM_KEYS" -gt 0 ]; then
echo " License keys : ${NUM_KEYS} (auto-fallback)"
fi
echo " Strategy  : round-robin"
echo "========================================"
echo ""

# ---- helper: generate GOST YAML config for round-robin ----
generate_gost_config() {
    local config_file="/tmp/gost-config.yaml"
    local ss_pass="${PROXY_PASS:-cloudflare-warp}"
    local ss_method="${SS_METHOD:-chacha20-ietf-poly1305}"
    local climiter_val="${PROXY_MAX_CONN:-10}"
    local rlimiter_val="${PROXY_MAX_RPS:-10}"

    # --- chain node list ---
    local nodes=""
    for i in $(seq 0 $((WARP_INSTANCES - 1))); do
        local port=$((40000 + i))
        nodes="${nodes}
    - name: warp-${i}
      addr: 127.0.0.1:${port}
      connector:
        type: socks5
      dialer:
        type: tcp"
    done

    # --- proxy auth block (SOCKS5 / HTTP handlers) ---
    local proxy_auth=""
    if [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
        proxy_auth="
    auth:
      username: ${PROXY_USER}
      password: ${PROXY_PASS}"
    fi

    # --- admission (IP whitelist) ---
    local admission_ref=""
    local admission_section=""
    if [ -n "$PROXY_ALLOWED_IPS" ]; then
        admission_ref="
  admission: admission-0"
        local matchers=""
        IFS=',' read -ra IPS <<< "$PROXY_ALLOWED_IPS"
        for ip in "${IPS[@]}"; do
            ip=$(echo "$ip" | xargs)  # trim whitespace
            matchers="${matchers}
  - ${ip}"
        done
        admission_section="
admissions:
- name: admission-0
  whitelist: true
  matchers:${matchers}"
    fi

    # --- write YAML ---
    cat > "$config_file" <<EOF
services:
# ---- WARP proxies (round-robin) ----
- name: socks5-warp
  addr: ":1080"
  handler:
    type: socks5
    chain: warp-chain${proxy_auth}
  listener:
    type: tcp
  climiter: climiter-0
  rlimiter: rlimiter-0${admission_ref}

- name: http-warp
  addr: ":8080"
  handler:
    type: http
    chain: warp-chain${proxy_auth}
  listener:
    type: tcp
  climiter: climiter-0
  rlimiter: rlimiter-0${admission_ref}

- name: ss-warp
  addr: ":8388"
  handler:
    type: ss
    chain: warp-chain
    auth:
      username: ${ss_method}
      password: ${ss_pass}
  listener:
    type: tcp
  climiter: climiter-0
  rlimiter: rlimiter-0${admission_ref}

# ---- Direct proxies (bypass WARP) ----
- name: socks5-direct
  addr: ":1081"
  handler:
    type: socks5${proxy_auth}
  listener:
    type: tcp
  climiter: climiter-0
  rlimiter: rlimiter-0${admission_ref}

- name: http-direct
  addr: ":8081"
  handler:
    type: http${proxy_auth}
  listener:
    type: tcp
  climiter: climiter-0
  rlimiter: rlimiter-0${admission_ref}

- name: ss-direct
  addr: ":8389"
  handler:
    type: ss
    auth:
      username: ${ss_method}
      password: ${ss_pass}
  listener:
    type: tcp
  climiter: climiter-0
  rlimiter: rlimiter-0${admission_ref}

# ---- Round-robin chain ----
chains:
- name: warp-chain
  hops:
  - name: warp-hop
    selector:
      strategy: round
      maxFails: 3
      failTimeout: 30s
    nodes:${nodes}

# ---- Limiters ----
climiters:
- name: climiter-0
  limits:
  - '\$ ${climiter_val}'

rlimiters:
- name: rlimiter-0
  limits:
  - '\$ ${rlimiter_val}'
${admission_section}
EOF

    echo "GOST config written to ${config_file}"
}

# ---- start each WARP instance with isolated paths ----
INSTANCE_PIDS=()
for i in $(seq 0 $((WARP_INSTANCES - 1))); do
    PORT=$((40000 + i))
    /start-warp-instance.sh \
        "$i" "$PORT" "$LICENSE_KEYS_CSV" "${WARP_CONNECT_TIMEOUT:-30}" &
    INSTANCE_PIDS+=($!)
    sleep 3  # stagger to avoid Cloudflare API rate-limiting
done

# ---- verify each instance is connected to WARP (parallel) ----
echo ""
echo "Verifying WARP instances (parallel)..."
READY_COUNT=0
MAX_VERIFY_WAIT=90
VERIFY_DIR=$(mktemp -d)
VERIFY_PIDS=()

for i in $(seq 0 $((WARP_INSTANCES - 1))); do
    (
        PORT=$((40000 + i))
        WAIT=0
        while [ "$WAIT" -lt "$MAX_VERIFY_WAIT" ]; do
            if curl -s --connect-timeout 3 --socks5 "127.0.0.1:${PORT}" \
                "https://cloudflare.com/cdn-cgi/trace" 2>/dev/null | grep -qE 'warp=(on|plus)'; then
                echo "OK" > "${VERIFY_DIR}/${i}"
                exit 0
            fi
            sleep 3
            WAIT=$((WAIT + 3))
        done
        exit 1
    ) &
    VERIFY_PIDS+=($!)
done

for pid in "${VERIFY_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done

for i in $(seq 0 $((WARP_INSTANCES - 1))); do
    PORT=$((40000 + i))
    if [ -f "${VERIFY_DIR}/${i}" ]; then
        echo "  Instance ${i}: OK (port ${PORT})"
        READY_COUNT=$((READY_COUNT + 1))
    else
        echo "  Instance ${i}: FAILED (port ${PORT} not responding after ${MAX_VERIFY_WAIT}s)"
    fi
done
rm -rf "$VERIFY_DIR"

echo ""
echo "${READY_COUNT}/${WARP_INSTANCES} WARP instances ready"

if [ "$READY_COUNT" -eq 0 ]; then
    echo "Error: no WARP instances started successfully. Exiting."
    exit 1
fi

# ---- generate GOST config ----
generate_gost_config

# ---- summary ----
echo ""
echo "=== Proxy Endpoints (round-robin across ${READY_COUNT} IPs) ==="
echo "  SOCKS5 (WARP)  : :1080"
echo "  HTTP   (WARP)  : :8080"
echo "  SS     (WARP)  : :8388"
echo "  SOCKS5 (Direct): :1081"
echo "  HTTP   (Direct): :8081"
echo "  SS     (Direct): :8389"
if [ -n "$PROXY_USER" ]; then
    echo "  Auth: ${PROXY_USER}:***"
fi
echo "========================================================="
echo ""

# ---- cleanup on shutdown ----
cleanup() {
    echo "Shutting down ${WARP_INSTANCES} WARP instances..."
    for pid in "${INSTANCE_PIDS[@]}"; do
        sudo kill "$pid" 2>/dev/null || true
    done
    kill "$GOST_PID" 2>/dev/null || true
    wait
}
trap cleanup SIGTERM SIGINT

# ---- start GOST (foreground keeps container alive) ----
echo "Starting GOST proxy (round-robin across ${READY_COUNT} instances)..."
gost -C /tmp/gost-config.yaml &
GOST_PID=$!

wait $GOST_PID
