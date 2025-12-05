# Cloudflare WARP

[![Build and Test](https://github.com/ErcinDedeoglu/cloudflare-warp/actions/workflows/build-and-test.yml/badge.svg)](https://github.com/ErcinDedeoglu/cloudflare-warp/actions/workflows/build-and-test.yml)
[![Docker Pulls](https://img.shields.io/docker/pulls/dublok/cloudflare-warp)](https://hub.docker.com/r/dublok/cloudflare-warp)
[![GitHub](https://img.shields.io/github/license/ErcinDedeoglu/cloudflare-warp)](https://github.com/ErcinDedeoglu/cloudflare-warp/blob/v1.0/LICENSE)

Run the official [Cloudflare WARP](https://1.1.1.1/) client in Docker. This container provides a SOCKS5/HTTP proxy that routes your traffic through Cloudflare's network, hiding your real IP address.

> **Build and Test Badge**: The badge above indicates full functionality. A ✅ **passing** status means the image builds successfully, WARP connects, the proxy works, and your IP is properly masked (real IP ≠ WARP IP). Click the badge to see detailed test results.

## Quick Start

### 1. Create `docker-compose.yml`

```yaml
services:
  warp:
    image: dublok/cloudflare-warp:latest
    container_name: warp
    restart: always
    device_cgroup_rules:
      - 'c 10:200 rwm'
    ports:
      - "1080:1080"
    environment:
      - WARP_SLEEP=5
    cap_add:
      - MKNOD
      - AUDIT_WRITE
      - NET_ADMIN
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
    volumes:
      - ./data:/var/lib/cloudflare-warp
```

### 2. Start the Container

```bash
docker compose up -d
```

### 3. Test the Connection

```bash
curl --socks5-hostname 127.0.0.1:1080 https://cloudflare.com/cdn-cgi/trace
```

If working correctly, you'll see `warp=on` in the output.

## Usage

Use the proxy with any application that supports SOCKS5 or HTTP proxy:

```bash
# SOCKS5 proxy
curl --socks5-hostname 127.0.0.1:1080 https://example.com

# HTTP proxy  
curl -x http://127.0.0.1:1080 https://example.com
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------||
| `WARP_SLEEP` | Seconds to wait for WARP daemon to start | `2` |
| `WARP_LICENSE_KEY` | WARP+ license key (optional, runtime only) | - |
| `GOST_ARGS` | Custom GOST proxy arguments | `-L :1080` |
| `PROXY_USER` | Username for proxy authentication (optional) | - |
| `PROXY_PASS` | Password for proxy authentication (optional) | - |

### Using WARP+ License Key

To use a WARP+ license, pass it as a runtime environment variable (not at build time):

```bash
# Using docker run
docker run -e WARP_LICENSE_KEY=your-license-key ...

# Using docker-compose.yml
services:
  warp:
    environment:
      - WARP_LICENSE_KEY=your-license-key
```

**Security Note:** Never bake your license key into the image. Always provide it at runtime to prevent credential leakage in build logs or image metadata.

### Proxy Authentication

To require authentication when connecting to the proxy, set both `PROXY_USER` and `PROXY_PASS`:

```yaml
services:
  warp:
    environment:
      - PROXY_USER=myuser
      - PROXY_PASS=mysecretpassword
```

Then connect using credentials:

```bash
# SOCKS5 with authentication
curl --socks5 myuser:mysecretpassword@127.0.0.1:1080 https://cloudflare.com/cdn-cgi/trace

# HTTP proxy with authentication
curl -x http://myuser:mysecretpassword@127.0.0.1:1080 https://example.com
```

**Note:** If only one of `PROXY_USER` or `PROXY_PASS` is set, authentication will be disabled and the proxy will run without credentials.

## Troubleshooting

### Proxy timeout from host

If the proxy works inside the container but not from the host, your Docker network may be outside WARP's allowed IP range. Add a custom network with a subnet in the `172.16.0.0/12` range:

```yaml
services:
  warp:
    # ... other settings ...
    networks:
      - warp_net

networks:
  warp_net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.31.255.0/24
```

### IPv6 not supported

If you get an IPv6 error on startup, remove the IPv6 sysctl from your compose file. The example above already excludes it.

## Verify IP is Hidden

```bash
# Your real IP (without WARP)
curl https://ifconfig.me

# IP through WARP (should be different - Cloudflare IP)
curl --socks5-hostname 127.0.0.1:1080 https://ifconfig.me
```

## Author

**Ercin Dedeoglu**

- GitHub: [@ErcinDedeoglu](https://github.com/ErcinDedeoglu)
- LinkedIn: [ercindedeoglu](https://www.linkedin.com/in/ercindedeoglu)
- Email: e.dedeoglu@gmail.com

## License

MIT License - see [LICENSE](LICENSE) for details.
