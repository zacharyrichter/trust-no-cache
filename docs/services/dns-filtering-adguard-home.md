# AdGuard Home: DNS filtering for WireGuard clients

Config: [`configs/adguard/`](../../configs/adguard/)

## Purpose

Filtering DNS for devices on the VPS's WireGuard tunnel. It blocks ads, trackers, malware and phishing domains for those devices, wherever they happen to be.

## Why it's built this way

- **Only tunnel clients use it.** DNS listens on the tunnel's address (`10.77.0.1`) and nowhere else, so it is never an open resolver on the internet.
- **The host does not depend on it.** The VPS resolves through a public resolver (`/etc/resolv.conf`), so an AdGuard failure can't take down the host or the other containers. An earlier outage was a chain in which it could; see the [postmortem](../postmortem-cascading-dns-failure.md).
- **Docker waits for WireGuard.** AdGuard can only bind `10.77.0.1` once `wg0` exists. A systemd drop-in makes Docker start after `wg-quick@wg0` finishes ([vps-host-hardening.md](../vps-host-hardening.md#docker)).
- **Encrypted upstreams.** Queries leave the VPS over DNS-over-HTTPS to Quad9 and a second provider, with DNSSEC validation.
- **One set of allow-list rules, two AdGuards.** The allow-list exceptions are written once on the AdGuard at home and copied here by a sync job that runs at home; everything else stays local to the VPS. The VPS never connects into the home network to get them.

## Current state

**Container** ([`compose.yaml`](../../configs/adguard/compose.yaml)): `network_mode: host`, read-only root with tmpfs `/tmp`, `cap_drop: ALL` plus `NET_BIND_SERVICE`, `no-new-privileges`, `GOMEMLIMIT=1300MiB` under a 1536 MB container limit. Volumes `./config` and `./work`.

| Listener | What |
|---|---|
| `10.77.0.1:53` (TCP and UDP) | DNS for WireGuard clients |
| `*:3000` | Web UI. nftables allows it only from Traefik's address (`172.18.0.2`), so it is reachable only through Traefik: IP allowlist, basic auth, then AdGuard's own login. Other containers can't reach it |

**DNS settings** (`AdGuardHome.yaml`, not in this repo):

- Upstreams: Quad9 and a second DoH provider, load-balanced. Bootstrap and fallback: Quad9 DoH by IP.
- DNSSEC on, `refuse_any`, AAAA answers disabled, version/id/hostname queries blocked.
- 4 MB cache with optimistic caching (minimum TTL 300 s, maximum one day).
- Query log and statistics kept for one day.
- UI login lockout: 5 attempts, then a 15-minute block.
- No TLS or DoH serving of its own (Traefik handles TLS), and no DHCP.

**Filtering:** around twenty blocklists from AdGuard's registry (ads, trackers, malware, phishing, scams, stalkerware, crypto-mining, abused TLDs), safe browsing on, and a list of globally blocked services.

**Per-client settings** are keyed by each device's tunnel address. Some devices have their own filtering profiles; the rest use the global settings.

**Where to edit what.** Allow-list exceptions are edited on the home AdGuard; edits made on the VPS are overwritten at the next sync. Everything else (blocklists, blocked services, upstreams, client settings) is edited in the VPS's own UI and isn't synced.

## Procedure

- **Add a device:** add the WireGuard peer ([vps-host-hardening.md](../vps-host-hardening.md#add-a-peer)), then add a client by its tunnel address if it needs non-global settings.
- **After restarting WireGuard by hand:** `sudo docker restart adguard`.

## Verification

```bash
sudo ss -tulnp | grep -E '10\.77\.0\.1:53|:3000'
# From a WireGuard client: a normal domain resolves, a blocklisted one doesn't
dig @10.77.0.1 example.com +short
```

## Recovery

- **No DNS on `10.77.0.1` after boot:** check that `wg0` is up (`ip -br addr show wg0`), then `sudo docker restart adguard`.
- **UI unreachable:** check the Traefik route and `adguard-auth`, then the nftables rule for `:3000`, which allows only Traefik at `172.18.0.2` ([firewall-and-ddns-allowlist.md](../firewall-and-ddns-allowlist.md)).
- **Rebuild material:** `config/AdGuardHome.yaml` (settings, clients, rules) and `compose.yaml`. `work/` holds the query log, statistics and downloaded filter lists, which rebuild themselves.
