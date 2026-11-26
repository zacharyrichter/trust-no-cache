# Firewall and the dynamic-IP allowlist

A default-deny nftables firewall plus a small script that keeps one allowlist, driven by my home IP, consistent across the firewall and the reverse proxy.

The ruleset is [`configs/host/etc/nftables.conf`](../configs/host/etc/nftables.conf) and the updater is [`update-whitelist-ddns.sh`](../configs/host/usr/local/bin/update-whitelist-ddns.sh). The design reasoning is in the [README](../README.md); this page is the mechanism.

## What it enforces

- SSH is limited to an allowlist (the home IP, tracked dynamically), two static fallback addresses, and WireGuard clients.
- HTTPS (Traefik) is limited to the allowlist and WireGuard clients.
- WireGuard clients can reach Traefik, DNS, SSH and the internet. They get no direct container access, no private ranges, and no client-to-client traffic.
- Nothing can open a new connection *into* the tunnel.

```
 Home router ──updates──► Cloudflare DNS ◄──API read── update-whitelist-ddns.sh (every 5 min)
 (A record ddns.example.com)                                   │
                                              ┌────────────────┴───────────────┐
                                              ▼                                ▼
                                   nftables `whitelist` set          Traefik `ipAllowList`
```

## Standing rules for this host

1. **Never `systemctl restart` or `reload` `nftables.service`.** Its stop action flushes the entire ruleset, including Docker's own tables. Docker's unit also `Requires=` nftables, so stopping one stops the other. If it happens anyway, `sudo systemctl restart docker` rebuilds Docker's tables.
2. **Never persist with `nft list ruleset > /etc/nftables.conf`.** That would dump Docker's tables, with bridge names that go stale, into the config. `/etc/nftables.conf` holds only `inet filter` and `ip nat`. Docker's tables are Docker's.
3. **Firewall changes take effect at a planned reboot.** Edit the file, validate with `nft -c -f`, then reboot with the provider's console available and run the post-change checks below.

## Prerequisites

- A Debian host with `sudo`, and the provider's web console as a fallback.
- `nftables`, `curl` and `python3`.
- A Cloudflare-managed domain with an A record (`ddns.example.com`) that a DDNS client at home keeps pointed at the home IP.
- WireGuard on `wg0` (`10.77.0.1/24`) and Docker with `"firewall-backend": "nftables"`.

## Step 1: a read-only, address-locked Cloudflare token

The script only reads one DNS record, so its token must not be able to write DNS.

1. Cloudflare dashboard → **My Profile** → **API Tokens** → **Create Token** → **Create Custom Token**.
2. Permissions: *Zone* → *DNS* → **Read**.
3. Zone resources: *Include* → *Specific zone* → `example.com`.
4. Client IP address filtering, **Is in**, with the VPS's IPv4 address and its IPv6 /64 (curl may use either): `192.0.2.10` and `2001:db8:1234:5678::/64`.
5. Create the token and copy it; it is shown once.

Even a read-only copy would reveal the home IP, which is what the VPS exists to keep private. The address filter makes a leaked copy useless anywhere else.

Check the token from the VPS over both address families (each should print `True []`):

```bash
sudo bash -c 'source /etc/nftables-ddns.env; for v in 4 6; do printf "IPv$v: "; curl -$v -s -H "Authorization: Bearer $CF_API_TOKEN" https://api.cloudflare.com/client/v4/user/tokens/verify | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[\"success\"], d[\"errors\"])"; done'
```

## Step 2: zone ID and record ID

The zone ID is on the domain's **Overview** page, in the API section of the sidebar. The record ID isn't shown in the UI:

```bash
curl -s "https://api.cloudflare.com/client/v4/zones/<ZONE_ID>/dns_records?name=ddns.example.com" \
  -H "Authorization: Bearer <API_TOKEN>" | python3 -m json.tool
```

Use the `id` of the matching A record.

## Step 3: store the secrets outside the script

```bash
sudo nano /etc/nftables-ddns.env
```

```bash
CF_API_TOKEN="<API_TOKEN>"
CF_ZONE_ID="<ZONE_ID>"
CF_RECORD_ID="<RECORD_ID>"
CF_RECORD_NAME="ddns.example.com"
```

```bash
sudo chown root:root /etc/nftables-ddns.env
sudo chmod 600 /etc/nftables-ddns.env
```

## Step 4: the ruleset

Install `nftables`, enable it, then deploy [`nftables.conf`](../configs/host/etc/nftables.conf).

**Input (traffic to the host itself)**

| Rule | Purpose |
|---|---|
| ICMP and ICMPv6, specific types only, echo rate-limited | Ping, path-MTU and neighbour discovery |
| `udp dport 51820` | WireGuard |
| `wg0` → 53 | AdGuard DNS for WireGuard clients (it listens on `10.77.0.1:53`) |
| `wg0` → SSH | SSH fallback over the tunnel |
| from Traefik's fixed address (`172.18.0.2`), arriving on a Docker bridge → 3000 | Traefik to the AdGuard UI. AdGuard runs on the host network |
| `@whitelist` → SSH | SSH from the dynamic home IP |
| two static addresses → SSH | SSH from fixed fallback locations |

Over IPv6 only ICMPv6 and WireGuard are accepted; no service is exposed on IPv6.

**Forward (traffic routed through the host)**

- **Traefik (443).** Published ports are DNAT'd to `172.18.0.2:443`, so they are filtered in *forward*, not *input*. WireGuard clients are accepted. Any other source not in `@whitelist` is dropped, which means the two static SSH addresses can't reach Traefik.
- **WireGuard clients** reach the internet only. Client-to-client traffic, private ranges out of the public interface, and anything else (including direct container addresses) is dropped. Services are reached through Traefik.
- **Into the tunnel.** Nothing may open a new connection to a WireGuard client. Replies pass through the `ct state` rule.
- **Docker bridges.** General bridge traffic is accepted; Docker's own tables do the per-container filtering (see below).

The drop rules carry `counter`s, so `sudo nft list chain inet filter forward | grep counter` shows traffic. A rising count on `iifname "wg0" counter drop` during normal use means something is trying to bypass Traefik.

**Why the AdGuard UI rule matches an address, not a bridge.** It originally named the Docker bridge by its ID, which silently stops matching if the network is ever recreated. It now matches Traefik's fixed address arriving from any bridge. That is sturdier and tighter: other containers on the same network can no longer reach the UI (I checked: a request from another container to the UI timed out). The rule depends on `warpconduit` keeping `172.18.0.0/16` and Traefik keeping `.2`, which the compose files already depend on.

## Step 5: applying changes

**First install**, before Docker is running:

```bash
sudo nft -c -f /etc/nftables.conf     # syntax check only
sudo nft -f /etc/nftables.conf
sudo systemctl start nftables
```

**Any later change**, with Docker running (see the standing rules):

```bash
sudo cp -a /etc/nftables.conf /root/nftables.conf.bak-$(date +%F)
sudo nano /etc/nftables.conf
sudo nft -c -f /etc/nftables.conf && echo "SYNTAX OK"
sudo systemctl reboot                 # with the web console available
```

Then run the checks below and delete the backup.

A live `nft -f /etc/nftables.conf` only touches `inet filter` and `ip nat`, but it empties the `whitelist` set and locks SSH out from home until the timer refills it. Use the reboot.

## Step 6: Docker's own tables (reference)

With the nftables backend, Docker creates and fully manages `ip docker-bridges` and `ip6 docker-bridges`. They are rebuilt on every Docker start and are **not** part of `/etc/nftables.conf`. Don't edit them.

| Chain | Purpose |
|---|---|
| `raw-PREROUTING` | One `DROP DIRECT ACCESS` rule per container address (traffic to a container address that doesn't arrive on its own bridge is dropped), plus `DROP REMOTE LOOPBACK` |
| `nat-prerouting-and-output` | DNAT for published ports |
| `filter-FORWARD` and per-bridge chains | Per-bridge filtering; unpublished ports hit `UNPUBLISHED PORT DROP` |
| `nat-POSTROUTING` and per-bridge chains | Masquerade for container egress |

Docker generates the `DROP DIRECT ACCESS` rules for every container itself, including new ones, so no manual rules are needed. Bridge names (`br-<id>`) change whenever a network is recreated, so no rule in `nftables.conf` names one.

| Container | Network | Address |
|---|---|---|
| traefik | warpconduit | 172.18.0.2 (fixed) |
| ntfy | warpconduit | 172.18.0.7 (fixed) |
| freshrss | warpconduit | 172.18.0.50 (fixed) |
| adguard | host network | none |

The only published port is **443**, to Traefik. Everything else is reachable only through Traefik or inside its own Docker network.

```bash
sudo nft list chain ip docker-bridges raw-PREROUTING             # one DROP DIRECT ACCESS per container address
sudo nft list chain ip docker-bridges nat-prerouting-and-output  # published ports
```

If a container's `DROP DIRECT ACCESS` rule is missing, `sudo systemctl restart docker` regenerates the table.

## Step 7: the updater script

[`update-whitelist-ddns.sh`](../configs/host/usr/local/bin/update-whitelist-ddns.sh) (root, mode 700) does this on each run:

1. Reads the A record from the Cloudflare API and aborts, with a logged error, on any non-200 response, an API-reported failure, or a value that isn't a dotted IPv4 address.
2. Compares the result with the last known address in `/var/lib/nftables-ddns/ip` **and** checks whether that address is actually in the live nftables set. It exits quietly only if both match.
3. On a change, removes the old address from the set, adds the new one, and records it.
4. Rewrites the matching `/32` entry in Traefik's `ipAllowList` so the proxy layer follows the same value. Traefik watches the file and picks it up.

Step 2 is the important one. The state file survives reboots; the nftables set does not. After a reboot the address is unchanged but the set is empty, so the script notices, logs "IP unchanged; ensuring … is present", and refills it. An earlier version checked only its state file and would have reported success indefinitely after the live set was cleared.

The Traefik edit depends on the `ipAllowList:` / `sourceRange:` structure in `fileConfig.yml` staying as it is.

## Step 8: service and timer

[`nftables-ddns.service`](../configs/host/etc/systemd/system/nftables-ddns.service) is a oneshot that wants `network-online.target` and runs after `nftables.service`. [`nftables-ddns.timer`](../configs/host/etc/systemd/system/nftables-ddns.timer) fires 15 seconds after boot and every five minutes after that.

`Wants=` and `After=` belong in the *service*, the unit that needs the network and the set. In the timer they had no effect on the script.

```bash
sudo systemd-analyze verify /etc/systemd/system/nftables-ddns.service /etc/systemd/system/nftables-ddns.timer
sudo systemctl daemon-reload
sudo systemctl enable --now nftables-ddns.timer
systemctl list-timers nftables-ddns.timer
sudo /usr/local/bin/update-whitelist-ddns.sh      # first run
cat /run/nftables-ddns.log
sudo nft list set inet filter whitelist
```

## Post-reboot and post-change checks

**On the VPS:**

```bash
sudo nft list tables                       # 4: inet filter, ip nat, ip docker-bridges, ip6 docker-bridges
sudo nft list set inet filter whitelist    # home IP present (allow up to 5 minutes after boot)
sudo docker ps --format '{{.Names}}: {{.Status}}' | sort   # all containers Up
sudo wg show wg0 | head -5                 # interface up, listening on 51820
systemctl --failed                         # 0 units
```

**From a WireGuard client:**

```bash
curl -sm5 -o /dev/null -w "internet: %{http_code}\n" https://example.org          # 200
curl -sm5 -o /dev/null -w "traefik: %{http_code}\n" https://rss.example.net       # 200/302/401
curl -m5 http://172.18.0.50 ; echo "direct exit: $?"                               # times out, exit 28
ssh vps 'echo ssh ok'                                                              # ssh ok
```

The "direct exit: 28" line is the one that matters: a client that goes around Traefik must fail.

## File reference

| Path | Purpose |
|---|---|
| `/etc/nftables.conf` | Ruleset (`inet filter` and `ip nat` only) |
| `/etc/nftables-ddns.env` | Cloudflare token, zone ID, record ID and name (root, 600). Not in the repo |
| `/usr/local/bin/update-whitelist-ddns.sh` | Updater (root, 700) |
| `/etc/systemd/system/nftables-ddns.{service,timer}` | Oneshot and timer |
| `/var/lib/nftables-ddns/ip` | Last known home IP (persistent) |
| `/run/nftables-ddns.log` | Runtime log (tmpfs, cleared on reboot) |
| `/opt/appdata/traefik/config/fileConfig.yml` | Traefik dynamic config that holds the `ipAllowList` |

## Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| `HTTP 000` in the log | Script ran before the network was ready | Usually clears on the next run; check `systemctl status network-online.target` |
| SSH or HTTPS blocked from home | Allowlist empty or stale | `cat /run/nftables-ddns.log`; run the script by hand |
| `HTTP 401` from Cloudflare | Token expired or revoked | Create a new read-only token (Step 1) and update the env file |
| `HTTP 403` from Cloudflare | Token lacks *Zone → DNS → Read*, or the request came from outside the token's address filter (for example the VPS's IPv6 prefix changed) | Run the token check in Step 1; fix the permission or the filter |
| Allowlist updated but Traefik still blocks | `fileConfig.yml` not picked up, or the `ipAllowList` structure changed | `sudo docker logs traefik`; check the `sourceRange` entry |
| Only 2 tables after a change; containers unreachable | `nftables.service` was restarted or reloaded and flushed Docker's tables | `sudo systemctl restart docker` |
| AdGuard UI unreachable through Traefik | Traefik is no longer at `172.18.0.2`, or AdGuard isn't on `:3000` | `sudo docker inspect traefik -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'`; `sudo ss -tlnp \| grep 3000` |
| WireGuard client can't reach a service | The service isn't behind Traefik (direct container access is blocked by design) | Add a Traefik route. If unavoidable, add a narrow `ip saddr <client> ip daddr <container> tcp dport <port> accept` above `iifname "wg0" counter drop` |
| `DROP DIRECT ACCESS` rule missing for a container | Docker's table is out of date | `sudo systemctl restart docker` |
