# Traefik: the single entry point

Config: [`configs/traefik/`](../../configs/traefik/)

## Purpose

Traefik is the one way into every web service on the VPS. It terminates TLS, routes by hostname, and applies an IP allowlist, a rate limit and security headers before anything reaches a service.

## Why it's built this way

- **One door.** Only port 443 is published. Every service, including the ones WireGuard clients use, is reached through Traefik and never directly.
- **Two layers on who can connect.** nftables drops 443 traffic from anyone outside the allowlist or WireGuard before Traefik sees it. Traefik's `local-ipwhitelist` checks the same thing again, from the same source (see [firewall-and-ddns-allowlist.md](../firewall-and-ddns-allowlist.md)), so a firewall mistake alone doesn't open a service.
- **File provider only.** Routers are written by hand in `fileConfig.yml`. There is no Docker-socket provider, so Traefik has no access to the Docker API.
- **Modern TLS only.** TLS 1.3 minimum, `sniStrict`, and P-521/P-384/P-256 curves. Every client I use supports this.

## Current state

**Container** ([`compose.yaml`](../../configs/traefik/compose.yaml)): publishes `443:443` only, fixed address `172.18.0.2` on the `warpconduit` network. Read-only root filesystem, tmpfs `/tmp`, all capabilities dropped, `no-new-privileges`, 256 MB memory limit, `restart: always`. The config directory is mounted at `/etc/traefik/`. The Cloudflare DNS API token for certificate issuance comes from `.env`, which is not in this repo.

**Static config** ([`traefik.yml`](../../configs/traefik/config/traefik.yml)):

- One entry point, `https` on `:443`. `forwardedHeaders.trustedIPs` is `172.16.0.0/12`, so forwarded headers are trusted only from Docker networks.
- Default TLS from Let's Encrypt via the DNS challenge (Cloudflare), as a wildcard certificate for the domain. Because it's a DNS challenge, no port 80 is ever opened.
- File provider only, watched for changes. Dashboard off. Anonymous usage reporting off.
- Logs: `traefik.log` at INFO level with Traefik's own rotation (10 MB, 3 backups, 7 days), and `access.log` for status codes 200–599 with headers dropped. A logrotate rule ([`traefik`](../../configs/host/etc/logrotate.d/traefik), weekly, four kept, `copytruncate`) covers the files.

**Dynamic config** ([`fileConfig.yml`](../../configs/traefik/config/fileConfig.yml)):

| Router | Host | Middlewares | Backend |
|---|---|---|---|
| adguard | `adguard.example.net` | `secured-chain`, `adguard-auth` (basic auth) | `http://172.18.0.1:3000`, AdGuard on the host network, reached through the bridge gateway |
| freshrss | `rss.example.net` | `secured-chain` | `http://172.18.0.50:80` |
| ntfy | `ntfy.example.net` | `ntfy-chain` | `http://ntfy:80` |

**Middlewares:**

| Middleware | What it does |
|---|---|
| `local-ipwhitelist` | `ipAllowList` of Docker networks, WireGuard clients, and the current home address. The home entry is the one the DDNS script rewrites |
| `strip-proxy-headers` | Sets `X-Forwarded-Proto: https` for upstream apps. Despite the name it strips nothing: spoofed `X-Forwarded-*` headers from outside are handled by `trustedIPs` |
| `rate-limit` | Average 100 requests per second, burst 50 |
| `securityHeaders` | HSTS with preload (one year, subdomains), `nosniff`, referrer policy, same-origin framing, a restrictive permissions policy, cross-origin isolation headers, and an empty `Server` header |
| `adguard-auth` | Basic auth from a users file (`adguard.htpasswd`, not in this repo) |
| `compress` | Response compression |
| `secured-chain` | `strip-proxy-headers` → `local-ipwhitelist` → `rate-limit` → `securityHeaders` → `compress` |
| `ntfy-chain` | The same, without the proxy-header step |

The chain runs in the order clean, authorize, secure, compress.

## Procedure

- **Add a service.** Put its container on `warpconduit` (give it a fixed address only if something else, like a firewall rule, depends on it), add a router and a service to `fileConfig.yml` using `secured-chain@file`, and add the hostname in Cloudflare DNS. The file is watched, so no restart is needed.
- **Keep the `ipAllowList:` / `sourceRange:` structure** in `local-ipwhitelist`. The DDNS script edits that block with `sed` and depends on its layout.
- **Updates** come from the nightly `docker-update` run ([vps-host-hardening.md](../vps-host-hardening.md#updates)).

## Verification

```bash
sudo docker ps --filter name=traefik --format '{{.Names}} {{.Status}}'
sudo docker logs --tail 20 traefik
sudo docker inspect traefik -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'   # 172.18.0.2
```

```bash
sudo ss -tlnp | grep ':443 '
sudo tail -5 /opt/appdata/traefik/config/logs/traefik.log
# TLS 1.2 must be refused (run from an allowed client)
openssl s_client -connect rss.example.net:443 -servername rss.example.net -tls1_2 </dev/null 2>&1 | grep -iE 'alert|handshake failure'
```

From a trusted address, `https://rss.example.net` should answer. From anywhere else it should not connect at all, because the firewall drops it first.

## Recovery

- **Bad `fileConfig.yml` edit:** Traefik logs the error and keeps the last good configuration. Fix the file; it reloads on save.
- **`fileConfig.yml: no such file or directory` in `traefik.log`:** expected after anything edits the file with `sed -i`, which the DDNS script does on every home-IP change. `sed -i` swaps in a new file and Traefik logs the brief gap. If in doubt, `sudo docker restart traefik` (a few seconds of downtime) makes it re-read and re-watch the file.
- **Certificates:** `acme.json` holds the issued certificates and the ACME account key. Without it, certificates are re-issued through the DNS challenge at start, which needs the Cloudflare token from `.env`.
- **Rebuild material:** `config/` (both YAML files, `acme.json`, the users file), `compose.yaml` and `.env`.
