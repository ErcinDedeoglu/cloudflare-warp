# Cloudflare WARP

[![Build, Test & Push](https://img.shields.io/github/actions/workflow/status/ErcinDedeoglu/cloudflare-warp/build-test-push.yml?branch=v1.0&logo=github&label=Build)](https://github.com/ErcinDedeoglu/cloudflare-warp/actions/workflows/build-test-push.yml)
[![Docker Pulls](https://img.shields.io/docker/pulls/dublok/cloudflare-warp?logo=docker&label=Pulls)](https://hub.docker.com/r/dublok/cloudflare-warp)
[![Docker Image Size](https://img.shields.io/docker/image-size/dublok/cloudflare-warp/latest?logo=docker&label=Size)](https://hub.docker.com/r/dublok/cloudflare-warp)
[![GitHub Stars](https://img.shields.io/github/stars/ErcinDedeoglu/cloudflare-warp?logo=github&label=Stars)](https://github.com/ErcinDedeoglu/cloudflare-warp)
[![License: CC BY-NC 4.0](https://img.shields.io/badge/License-CC%20BY--NC%204.0-blue.svg)](https://github.com/ErcinDedeoglu/cloudflare-warp/blob/v1.0/LICENSE)

Run [Cloudflare WARP](https://1.1.1.1/) in Docker. Provides SOCKS5 and HTTP proxies that route traffic through Cloudflare's network. Supports multiple WARP instances in a single container for IP rotation.

## Quick Start

```yaml
services:
  warp:
    image: dublok/cloudflare-warp:latest
    container_name: warp
    restart: always
    ports:
      - "1080:1080"  # SOCKS5 proxy
      # - "8080:8080"  # HTTP proxy
    volumes:
      - warp-data:/var/lib/cloudflare-warp

volumes:
  warp-data:
```

```bash
docker compose up -d

# Test SOCKS5 proxy
curl --socks5-hostname 127.0.0.1:1080 https://cloudflare.com/cdn-cgi/trace

# Test HTTP proxy (if port 8080 exposed)
curl -x http://127.0.0.1:8080 https://cloudflare.com/cdn-cgi/trace
```

If working, you'll see `warp=on` in the output.

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `WARP_INSTANCES` | Number of WARP instances. Each gets a unique Cloudflare IP. Traffic is round-robined across all instances. No extra capabilities required | `1` |
| `WARP_LICENSE_KEY` | WARP+ license key | - |
| `WARP_CONNECT_TIMEOUT` | Max seconds to wait for WARP daemon | `30` |
| `PROXY_USER` | Proxy authentication username | - |
| `PROXY_PASS` | Proxy authentication password | - |
| `PROXY_ALLOWED_IPS` | IP whitelist (comma-separated CIDRs) | - |
| `PROXY_MAX_CONN` | Max concurrent connections per IP | `10` |
| `PROXY_MAX_RPS` | Max requests per second per IP | `10` |
| `SS_METHOD` | Shadowsocks encryption method | `chacha20-ietf-poly1305` |

## With Authentication

```yaml
services:
  warp:
    image: dublok/cloudflare-warp:latest
    ports:
      - "1080:1080"  # SOCKS5 proxy
      - "8080:8080"  # HTTP proxy
    environment:
      - PROXY_USER=myuser
      - PROXY_PASS=mypassword
    volumes:
      - warp-data:/var/lib/cloudflare-warp

volumes:
  warp-data:
```

```bash
# SOCKS5 with auth
curl --socks5-hostname myuser:mypassword@127.0.0.1:1080 https://cloudflare.com/cdn-cgi/trace

# HTTP with auth
curl -x http://myuser:mypassword@127.0.0.1:8080 https://cloudflare.com/cdn-cgi/trace
```

## Direct Proxy (Bypass WARP)

Direct proxies are always available that exit through Docker's network without routing through WARP. Useful when you need your real IP for certain services.

| Port | Protocol | Route |
|------|----------|-------|
| 1080 | SOCKS5 | Through WARP (Cloudflare IP) |
| 1081 | SOCKS5 | Direct (real IP) |
| 8080 | HTTP | Through WARP (Cloudflare IP) |
| 8081 | HTTP | Direct (real IP) |

```yaml
services:
  warp:
    image: dublok/cloudflare-warp:latest
    ports:
      - "1080:1080"  # SOCKS5 WARP proxy
      - "1081:1081"  # SOCKS5 Direct proxy
      - "8080:8080"  # HTTP WARP proxy
      - "8081:8081"  # HTTP Direct proxy
    environment:
      - PROXY_USER=myuser
      - PROXY_PASS=mypassword
    volumes:
      - warp-data:/var/lib/cloudflare-warp

volumes:
  warp-data:
```

```bash
# SOCKS5 through WARP (Cloudflare IP)
curl --socks5-hostname myuser:mypassword@127.0.0.1:1080 https://ifconfig.me

# SOCKS5 direct exit (your real IP)
curl --socks5-hostname myuser:mypassword@127.0.0.1:1081 https://ifconfig.me

# HTTP through WARP (Cloudflare IP)
curl -x http://myuser:mypassword@127.0.0.1:8080 https://ifconfig.me

# HTTP direct exit (your real IP)
curl -x http://myuser:mypassword@127.0.0.1:8081 https://ifconfig.me
```

## Multi-Instance (IP Rotation)

Set `WARP_INSTANCES=N` to run multiple WARP daemons in a single container, each with a unique Cloudflare IP. Traffic is round-robined across all instances on the same ports — no extra capabilities required.

```yaml
environment:
  - WARP_INSTANCES=10    # each request exits through a different IP
```

Each instance uses ~50-100 MB RAM and starts 2 seconds apart. If an instance fails, GOST skips it after 3 failures and retries after 30s.

## Mobile VPN (Shadowsocks)

Connect your mobile devices using Shadowsocks apps - works as a system-wide VPN without requiring special Docker privileges. **Shadowsocks is always enabled** on ports 8388/8389.

### Supported Apps

| Platform | App | Price |
|----------|-----|-------|
| Android | [Shadowsocks](https://play.google.com/store/apps/details?id=com.github.shadowsocks) | Free |
| Android | [v2rayNG](https://play.google.com/store/apps/details?id=com.v2ray.ang) | Free |
| iOS | [Shadowrocket](https://apps.apple.com/app/shadowrocket/id932747118) | ~$3 |
| iOS | [Potatso Lite](https://apps.apple.com/app/potatso-lite/id1239860606) | Free |

### Setup

```yaml
services:
  warp:
    image: dublok/cloudflare-warp:latest
    ports:
      - "8388:8388"  # Shadowsocks WARP (Cloudflare IP)
      - "8389:8389"  # Shadowsocks Direct (real IP)
    environment:
      - PROXY_PASS=your-secure-password  # Optional: sets password for all protocols
    volumes:
      - warp-data:/var/lib/cloudflare-warp

volumes:
  warp-data:
```

### Mobile App Configuration

| Setting | Value |
|---------|-------|
| Server | Your server IP or domain |
| Port | `8388` (WARP) or `8389` (Direct) |
| Password | Your `PROXY_PASS` or `cloudflare-warp` (default) |
| Method | `chacha20-ietf-poly1305` (default) |

### Available Encryption Methods

**Recommended (AEAD):**
- `chacha20-ietf-poly1305` (default, recommended for mobile)
- `aes-256-gcm`
- `aes-128-gcm`

**Shadowsocks 2022 (newest, requires base64 key as password):**
- `2022-blake3-aes-128-gcm`
- `2022-blake3-aes-256-gcm`
- `2022-blake3-chacha20-poly1305`

**Other:**
- `xchacha20-ietf-poly1305`
- `chacha20-poly1305`

### Port Reference

| Port | Protocol | Route |
|------|----------|-------|
| 8388 | Shadowsocks | Through WARP (Cloudflare IP) |
| 8389 | Shadowsocks | Direct (real IP) |

## License

CC-BY-NC-4.0 - Non-commercial use only with attribution.
