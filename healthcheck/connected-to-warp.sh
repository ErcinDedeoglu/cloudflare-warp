#!/bin/bash

# Check WARP connection directly through WARP's internal proxy (port 40000)
# This bypasses GOST authentication for healthcheck purposes
curl -fsS --socks5-hostname 127.0.0.1:40000 "https://cloudflare.com/cdn-cgi/trace" | grep -qE "warp=(plus|on)" || exit 1
exit 0
