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
|----------|-------------|---------|
| `WARP_SLEEP` | Seconds to wait for WARP daemon to start | `2` |
| `WARP_LICENSE_KEY` | WARP+ license key (optional, runtime only) | - |
| `GOST_ARGS` | Custom GOST proxy arguments | `-L :1080` |
| `PROXY_USER` | Username for proxy authentication (optional) | - |
| `PROXY_PASS` | Password for proxy authentication (optional) | - |
| `PROXY_ALLOWED_IPS` | IP whitelist - only these IPs/CIDRs can connect (optional) | - |
| `PROXY_AUTH_FAIL_LIMIT` | Failed auth attempts before ban | `5` |
| `PROXY_AUTH_BAN_TIME` | Ban duration in seconds after failed auth | `300` (5 min) |
| `PROXY_AUTH_FAIL_WINDOW` | Time window to count failures in seconds | `60` |
| `PROXY_MAX_CONN` | Max concurrent connections per IP | `10` |
| `PROXY_MAX_RPS` | Max requests per second per IP | `10` |

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

### IP Whitelist (Recommended for Private Use)

For maximum security, restrict access to specific IP addresses or networks using `PROXY_ALLOWED_IPS`. Only connections from these IPs will be accepted - all others are immediately rejected before authentication.

```yaml
services:
  warp:
    environment:
      - PROXY_ALLOWED_IPS=192.168.1.0/24,10.0.0.0/8
```

Supported formats:
- Single IP: `192.168.1.100`
- CIDR range: `192.168.1.0/24`
- Multiple (comma-separated): `192.168.1.0/24,10.0.0.0/8,172.16.0.0/12`

**This is the most effective protection against brute-force attacks** - unauthorized IPs cannot even attempt authentication.

### Authentication Failure Tracking (Fail2Ban-Style)

When authentication is enabled, the container monitors GOST logs and **automatically bans IPs** that have too many failed authentication attempts:

- **`PROXY_AUTH_FAIL_LIMIT`**: Max failed attempts before ban (default: 5)
- **`PROXY_AUTH_BAN_TIME`**: Ban duration in seconds (default: 300 = 5 minutes)
- **`PROXY_AUTH_FAIL_WINDOW`**: Time window to count failures (default: 60 seconds)

```yaml
services:
  warp:
    environment:
      - PROXY_USER=myuser
      - PROXY_PASS=mysecretpassword
      - PROXY_AUTH_FAIL_LIMIT=3    # Ban after 3 failed attempts
      - PROXY_AUTH_BAN_TIME=600    # Ban for 10 minutes
      - PROXY_AUTH_FAIL_WINDOW=120 # Count failures within 2 minute window
```

**How it works:**
1. GOST logs authentication events at INFO level
2. A background monitor parses GOST's stdout for SOCKS5 authentication failures
3. When GOST detects invalid credentials, it logs the UserPassResponse (status=1 indicates failure)
4. Each failed attempt from an IP is tracked with a timestamp
5. If an IP exceeds `PROXY_AUTH_FAIL_LIMIT` failures within `PROXY_AUTH_FAIL_WINDOW` → **banned**
6. Banned IPs are blocked at the kernel level (iptables) for `PROXY_AUTH_BAN_TIME` seconds
7. After the ban expires, the IP is automatically unbanned

**Technical details:**
- GOST SOCKS5 handler logs `UserPassResponse` on auth failure (source: go-gost/x handler/socks/v5/selector.go)
- The monitor detects patterns like `"1 1"` (SOCKS5 version=1, status=1=Failure), `ErrAuthFailure`, etc.
- Client IPs are extracted from the `remote` field in GOST's log output

**This is true authentication failure tracking** - it detects and counts actual failed login attempts (wrong username/password), not just connection attempts.

### Rate Limiting

The proxy includes built-in rate limiting per IP address:

- **`PROXY_MAX_CONN`**: Maximum concurrent connections per IP (default: 10)
- **`PROXY_MAX_RPS`**: Maximum requests per second per IP (default: 10)

```yaml
services:
  warp:
    environment:
      - PROXY_MAX_CONN=5    # Only 5 concurrent connections per IP
      - PROXY_MAX_RPS=5     # Only 5 requests/sec per IP
```

**Note:** These limits apply to established connections and proxy requests. For brute-force protection, the auth failure tracking (above) automatically bans IPs with failed login attempts.

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
