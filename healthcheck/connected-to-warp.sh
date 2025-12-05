#!/bin/bash

# Check WARP connection through the GOST SOCKS5 proxy (port 1080)
# which chains to WARP's internal proxy (port 40000)
curl -fsS --socks5-hostname 127.0.0.1:1080 "https://cloudflare.com/cdn-cgi/trace" | grep -qE "warp=(plus|on)" || exit 1
exit 0
