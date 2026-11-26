# System diagram

The picture behind the [README](../README.md). No new reasoning here.

## Who can reach what

```
                         Home router (DDNS client)
                                   │ updates A record when the IP changes
                                   ▼
                         Cloudflare DNS: ddns.example.com
                                   │ read via API, every 5 minutes
                                   ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ VPS                                                                      │
│                                                                          │
│  update-whitelist-ddns.sh  (systemd timer)                               │
│        │ same value, same run                                            │
│        ├──────────────────────┬─────────────────────────┐                │
│        ▼                      ▼                         │                │
│  nftables `whitelist` set   Traefik ipAllowList         │ verifies the   │
│  (empty on disk,            (fileConfig.yml)            │ live set       │
│   filled at runtime)                                    ▼                │
│                                                                          │
│  INPUT (default drop)                                                    │
│   udp 51820 ............ anyone (WireGuard)                              │
│   tcp 2222  ............ @whitelist, 2 static IPs, WireGuard clients     │
│   udp/tcp 53 ........... WireGuard clients only                          │
│   tcp 3000 (AdGuard UI) . Traefik's address only                         │
│                                                                          │
│  FORWARD (default drop)                                                  │
│   tcp 443 → Traefik .... @whitelist or WireGuard clients                 │
│   WireGuard clients → internet only (no private ranges, no peer-to-peer) │
│                                                                          │
│  Traefik (only published port: 443)                                      │
│   ipAllowList → rate limit → security headers → service                  │
│        ├── AdGuard Home UI   (+ basic auth)                              │
│        ├── FreshRSS                                                      │
│        └── ntfy                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

## The two VPNs

```
 Home network ──── home VPN ────  my devices
                                       │
                                       │ separate tunnel, separate keys,
                                       │ separate subnet, no route between
                                       ▼
 VPS ───────────── VPS WireGuard ───  my devices
```

The VPS has no route into the home network and holds no credentials for it. Its configuration is copied out by hand from a machine at home that connects *to* the VPS.

## Boot order

```
nftables.service ──┐
                   ├──► docker.service ──► containers
wg-quick@wg0 ──────┤     (also waits for     (Traefik, ntfy,
 (10.77.0.1 up)    │      / to be mounted     FreshRSS, AdGuard binds
                         read-write)          10.77.0.1:53)
```

Docker `Requires=` the firewall, so the ruleset is in place before any container starts. It only `Wants=` WireGuard, so a WireGuard failure costs AdGuard's DNS, not every container.

## Detection and alerts

```
 integrity-check (daily)  ┐
 debsums (weekly)         ├─► ntfy-sendmail / curl ─► ntfy on this VPS ─► phones
 unattended-upgrades      │
 docker-update (nightly)  ┘
 auditd ─► audit trail kept on the host
```
