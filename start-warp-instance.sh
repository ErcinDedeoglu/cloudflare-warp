#!/bin/bash

# Copyright (c) 2025 Ercin Dedeoglu
# Licensed under CC BY-NC 4.0 (Attribution-NonCommercial)
# https://github.com/ErcinDedeoglu/cloudflare-warp
#
# Helper script: starts a single WARP instance with isolated data/IPC paths.
# Called by entrypoint.sh as: /start-warp-instance.sh <instance> <port> <license_key> <timeout>
#
# Uses STATE_DIRECTORY and RUNTIME_DIRECTORY env vars (systemd convention)
# to give each warp-svc its own data dir and IPC socket — no extra
# capabilities required (no SYS_ADMIN, no mount namespaces).

set -e

INSTANCE=${1:?"Instance number required"}
PORT=${2:?"Port number required"}
LICENSE_KEY=${3:-}
CONNECT_TIMEOUT=${4:-30}

DATA_DIR="/data/warp-instance-${INSTANCE}"
RUN_DIR="/run/warp-${INSTANCE}"
DBUS_DIR="/run/dbus-${INSTANCE}"
DBUS_SOCK="${DBUS_DIR}/system_bus_socket"

echo "[Instance ${INSTANCE}] Starting (proxy port: ${PORT})..."
echo "[Instance ${INSTANCE}]   DATA_DIR=${DATA_DIR}"
echo "[Instance ${INSTANCE}]   RUN_DIR=${RUN_DIR}"
echo "[Instance ${INSTANCE}]   DBUS_DIR=${DBUS_DIR}"

# Create instance-specific directories
sudo mkdir -p "$DATA_DIR" "$RUN_DIR" "$DBUS_DIR"

# Start a per-instance D-Bus daemon (used for power-state notifications;
# non-critical in containers but reduces warp-svc log noise)
sudo dbus-daemon \
    --address="unix:path=${DBUS_SOCK}" \
    --config-file=/usr/share/dbus-1/system.conf \
    --nopidfile --nofork >/dev/null 2>&1 &
sleep 1

# Start warp-svc with custom paths via env vars
sudo env \
    STATE_DIRECTORY="$DATA_DIR" \
    RUNTIME_DIRECTORY="$RUN_DIR" \
    DBUS_SYSTEM_BUS_ADDRESS="unix:path=${DBUS_SOCK}" \
    warp-svc --accept-tos &
WARP_PID=$!

# Wait for the daemon to be ready
ELAPSED=0
while [ "$ELAPSED" -lt "$CONNECT_TIMEOUT" ]; do
    if sudo env RUNTIME_DIRECTORY="$RUN_DIR" DBUS_SYSTEM_BUS_ADDRESS="unix:path=${DBUS_SOCK}" \
        warp-cli --accept-tos status 2>/dev/null | grep -qE '(Status|Connected)'; then
        echo "[Instance ${INSTANCE}] WARP daemon ready after ${ELAPSED}s"
        break
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

if [ "$ELAPSED" -ge "$CONNECT_TIMEOUT" ]; then
    echo "[Instance ${INSTANCE}] Warning: daemon may not be fully ready after ${CONNECT_TIMEOUT}s, continuing anyway..."
fi

# Helper: run warp-cli for this instance
wcli() {
    sudo env RUNTIME_DIRECTORY="$RUN_DIR" DBUS_SYSTEM_BUS_ADDRESS="unix:path=${DBUS_SOCK}" \
        warp-cli --accept-tos "$@"
}

# Register if needed
if [ ! -f "${DATA_DIR}/reg.json" ]; then
    wcli registration new && echo "[Instance ${INSTANCE}] Registered!"
    if [ -n "$LICENSE_KEY" ]; then
        wcli registration license "$LICENSE_KEY" > /dev/null 2>&1 \
            && echo "[Instance ${INSTANCE}] License applied!" \
            || echo "[Instance ${INSTANCE}] Failed to apply license"
    fi
fi

# Set proxy mode, custom port, and connect
wcli mode proxy
wcli proxy port "$PORT"
wcli connect
wcli debug qlog disable

echo "[Instance ${INSTANCE}] WARP proxy active on localhost:${PORT}"

# Keep the script alive as long as warp-svc is running
wait $WARP_PID
