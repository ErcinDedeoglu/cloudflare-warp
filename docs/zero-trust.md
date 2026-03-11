# Zero Trust Enrollment (Free WARP+ Routing)

Cloudflare Zero Trust (free plan, up to 50 devices) provides WARP+ equivalent routing through Cloudflare's backbone network at no cost. The container supports headless enrollment using [service tokens](https://developers.cloudflare.com/cloudflare-one/tutorials/warp-on-headless-linux/) — no browser or interactive authentication required.

## Environment Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `WARP_ORG` | Zero Trust team/organization name | Yes |
| `WARP_AUTH_CLIENT_ID` | Service token Client ID | Yes |
| `WARP_AUTH_CLIENT_SECRET` | Service token Client Secret | Yes |

All three must be set together. `WARP_ORG` and `WARP_LICENSE_KEY` are mutually exclusive — setting both will produce an error.

## One-Time Setup

1. Create a free Zero Trust account at [one.dash.cloudflare.com](https://one.dash.cloudflare.com)
2. Set a team name under **Settings**
3. Create a service token under **Access controls > Service credentials > Service Tokens**
4. Add a device enrollment policy:
   - Go to **Team & Resources > Devices > Management > Device enrollment permissions**
   - Select **Manage**, then **Create new policy**
   - Set **Action** to **Service Auth**
   - Add a rule: **Include > Service Token > your token name**
   - Save the policy and add it to your enrollment permissions

## Usage

```yaml
services:
  warp:
    image: dublok/cloudflare-warp:latest
    ports:
      - "1080:1080"
    environment:
      - WARP_ORG=my-team-name
      - WARP_AUTH_CLIENT_ID=88bf3b6d86161464f6509f7219099e57.access
      - WARP_AUTH_CLIENT_SECRET=bdd31cbc4dec990953e39163fbbb194c93313ca9f0a6e420346af9d326b1d2a5
      - WARP_INSTANCES=5
    volumes:
      - warp-data:/var/lib/cloudflare-warp

volumes:
  warp-data:
```

## How It Works

When the Zero Trust env vars are set, the container writes an `mdm.xml` file to each WARP instance's data directory before starting `warp-svc`. The WARP client reads this file on startup and automatically enrolls into the organization using the service token. No manual `warp-cli registration` or browser interaction is needed.

The MDM config sets `service_mode=proxy` with the correct `proxy_port` per instance, so the WARP client starts directly in local proxy mode.

## Compatibility

Works with all existing features:

| Feature | Compatible | Notes |
|---------|------------|-------|
| Multi-instance IP rotation | Yes | Each instance enrolls as a separate device |
| GOST round-robin proxy | Yes | No changes needed |
| Proxy auth (`PROXY_USER`/`PROXY_PASS`) | Yes | Independent of WARP enrollment |
| Shadowsocks | Yes | Independent of WARP enrollment |
| Direct proxy bypass | Yes | Independent of WARP enrollment |
| Container cleanup on shutdown | Yes | `warp-cli registration delete` frees device slots |

## Limitations

- Free Zero Trust plan supports up to **50 devices** (each WARP instance = 1 device)
- Identity-based policies and logging are not available with service token auth
- Cloudflare trace shows `warp=on` (not `warp=plus`), but routing uses Cloudflare's backbone
- If the Zero Trust admin sets `allowed_to_leave=false` in the device profile, automatic deregistration on shutdown will not work and devices will accumulate

## References

- [Cloudflare: Deploy WARP on headless Linux machines](https://developers.cloudflare.com/cloudflare-one/tutorials/warp-on-headless-linux/)
- [Cloudflare: Managed deployment parameters](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/warp/deployment/mdm-deployment/parameters/)
- [Cloudflare: Device enrollment permissions](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/warp/deployment/device-enrollment/)
