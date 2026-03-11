#!/bin/bash

# Check WARP connection directly through WARP's internal proxy.
# This bypasses GOST authentication for healthcheck purposes.
#
# In multi-instance mode, /tmp/healthy-warp-ports lists the ports that
# passed verification at startup.  We check the first healthy port so the
# Docker healthcheck doesn't fail just because instance-0 is the one that
# happened to be dead.  Falls back to port 40000 for single-instance mode.

PORTS_FILE="/tmp/healthy-warp-ports"

if [ -f "$PORTS_FILE" ]; then
    PORT=$(head -n1 "$PORTS_FILE")
else
    PORT=40000
fi

curl -fsS --socks5-hostname "127.0.0.1:${PORT}" \
    "https://cloudflare.com/cdn-cgi/trace" | grep -qE "warp=(plus|on)" || exit 1
exit 0
