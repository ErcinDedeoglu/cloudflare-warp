# Cloudflare WARP

[![Build and Test](https://github.com/ErcinDedeoglu/cloudflare-warp/actions/workflows/build-and-test.yml/badge.svg)](https://github.com/ErcinDedeoglu/cloudflare-warp/actions/workflows/build-and-test.yml)
[![Docker Pulls](https://img.shields.io/docker/pulls/dublok/cloudflare-warp)](https://hub.docker.com/r/dublok/cloudflare-warp)
[![GitHub](https://img.shields.io/github/license/ErcinDedeoglu/cloudflare-warp)](https://github.com/ErcinDedeoglu/cloudflare-warp/blob/v1.0/LICENSE)

Run [Cloudflare WARP](https://1.1.1.1/) in Docker. Provides a SOCKS5 proxy that routes traffic through Cloudflare's network.

## Quick Start

```yaml
services:
  warp:
    image: dublok/cloudflare-warp:latest
    container_name: warp
    restart: always
    ports:
      - "1080:1080"
    volumes:
      - warp-data:/var/lib/cloudflare-warp

volumes:
  warp-data:
```

```bash
docker compose up -d
curl --socks5-hostname 127.0.0.1:1080 https://cloudflare.com/cdn-cgi/trace
```

If working, you'll see `warp=on` in the output.

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `WARP_LICENSE_KEY` | WARP+ license key | - |
| `WARP_CONNECT_TIMEOUT` | Max seconds to wait for WARP daemon | `30` |
| `PROXY_USER` | Proxy authentication username | - |
| `PROXY_PASS` | Proxy authentication password | - |
| `PROXY_ALLOWED_IPS` | IP whitelist (comma-separated CIDRs) | - |
| `PROXY_MAX_CONN` | Max concurrent connections per IP | `10` |
| `PROXY_MAX_RPS` | Max requests per second per IP | `10` |

## With Authentication

```yaml
services:
  warp:
    image: dublok/cloudflare-warp:latest
    ports:
      - "1080:1080"
    environment:
      - PROXY_USER=myuser
      - PROXY_PASS=mypassword
    volumes:
      - warp-data:/var/lib/cloudflare-warp

volumes:
  warp-data:
```

```bash
curl --socks5-hostname myuser:mypassword@127.0.0.1:1080 https://cloudflare.com/cdn-cgi/trace
```

## Direct Proxy (Bypass WARP)

A second proxy is always available on port 1081 that exits directly through Docker's network without routing through WARP. Useful when you need your real IP for certain services.

```yaml
services:
  warp:
    image: dublok/cloudflare-warp:latest
    ports:
      - "1080:1080"  # WARP proxy
      - "1081:1081"  # Direct proxy
    environment:
      - PROXY_USER=myuser
      - PROXY_PASS=mypassword
    volumes:
      - warp-data:/var/lib/cloudflare-warp

volumes:
  warp-data:
```

```bash
# Through WARP (Cloudflare IP)
curl --socks5-hostname myuser:mypassword@127.0.0.1:1080 https://ifconfig.me

# Direct exit (your real IP)
curl --socks5-hostname myuser:mypassword@127.0.0.1:1081 https://ifconfig.me
```

## License

CC-BY-NC-4.0 - Non-commercial use only with attribution.
