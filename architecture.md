# System Diagram

Visual reference for the design decisions covered in [`README.md`](README.md). No new
reasoning here — just the map.

```
                              ┌─────────────────────────┐
                              │   Home Network (DDNS)   │
                              │  updates A record on    │
                              │   IP change             │
                              └────────────┬────────────┘
                                           │ DNS A record
                                           ▼
                              ┌──────────────────────────┐
                              │      Cloudflare DNS      │
                              │   ddns.yourdomain.org    │
                              └────────────┬─────────────┘
                                           │ polled via API, every 5 min
                                           ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                                   VPS                                    │
│                                                                          │
│   ┌──────────────────────┐        writes to both, same run               │
│   │ update-whitelist-ddns│──────────────┬─────────────────────┐          │
│   │  (systemd timer)     │              │                     │          │
│   └──────────────────────┘              ▼                     ▼          │
│                              ┌─────────────────┐   ┌──────────────────┐  │
│                              │ nftables        │   │ Traefik          │  │
│                              │ whitelist set   │   │ ipAllowList      │  │
│                              │ (empty on disk, │   │(mirrors the same │  │
│                              │  live-verified  │   │ IP, same run)    │  │
│                              │  every run)     │   └──────────┬───────┘  │
│                              └────────┬────────┘              │          │
│                                       │                       │          │
│              ┌────────────────────────┴───────────────────────┘          │
│              │ default-deny input chain                                  │
│              │ (allowed: whitelist set, one static fallback IP,          │
│              │  WireGuard port — always open, gated separately)          │
│              ▼                                                           │
│   ┌────────────────────────────────────────────────────────────────────┐ │
│   │                          Docker (bridge network)                   │ │
│   │                                                                    │ │
│   │   ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐           │ │
│   │   │ SearXNG  │  │ Yattee   │  │ Redlib   │  │ Yarr     │  ...      │ │
│   │   │ (no auth)│  │ (no auth)│  │ (no auth)│  │ (no auth)│           │ │
│   │   └──────────┘  └──────────┘  └──────────┘  └──────────┘           │ │
│   │        all published ports reachable only through Traefik          │ │
│   └────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│   ┌──────────────────────┐                                               │
│   │  WireGuard (wg0)     │  — independent tunnel, own VPN mesh,          │
│   │  fallback VPN entry  │    no route into the home network's           │
│   │  point               │    primary VPN (see README: "Two              │
│   └──────────────────────┘    separate VPNs, on purpose")                │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

## Legend

- **Single source of truth**: the DDNS timer is the only writer to both enforcement points
  (nftables + Traefik) — see README, *"One source of truth, enforced twice."*
- **Two independent gates**: a request must clear the firewall *and* Traefik, both reading
  from the same IP, before reaching any service.
- **WireGuard is deliberately outside the whitelist path** — its own port, its own trust
  boundary, no dependency on the DDNS mechanism above it.
- **No edge between the VPS's WireGuard and the home network's primary VPN** — that gap is
  intentional, not missing.
