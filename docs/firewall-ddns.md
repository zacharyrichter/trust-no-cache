# Firewall & Dynamic IP Whitelist — Setup Guide

Referenced from [`server-hardening.md`](server-hardening.md) Sections 4 and 20.

## Overview

```
┌─────────────────────┐        ┌───────────────────────┐        ┌──────────────────────┐
│  Home Router/Client │──DNS──▶│  Cloudflare DNS       │◀──API──│  update-whitelist-   │
│  (updates A record) │        │  ddns.yourdomain.org  │        │  ddns.sh (on server) │
└─────────────────────┘        └───────────────────────┘        └──────────┬───────────┘
                                                                            │
                                                              ┌─────────────▼────────────┐
                                                              │  nftables whitelist set  │
                                                              │  + Traefik ipAllowList   │
                                                              └──────────────────────────┘
```

A systemd timer runs the script every 5 minutes. If your home IP changes, the script
detects the difference between the new Cloudflare A record and the last known IP, updates
the nftables whitelist set, and updates Traefik's `ipAllowList` config accordingly. See
Section 20 for the architectural rationale (why the whitelist set is empty on disk, why
the state file lives on tmpfs, and the self-healing logic in the script below).

## Prerequisites

- `nftables`, `curl`, `python3` installed
- A domain managed by Cloudflare with an A record pointing to your dynamic home IP
- A DDNS client on your home router/local machine keeping that A record current

## Step 1: Create a Cloudflare API Token

1. [Cloudflare dashboard](https://dash.cloudflare.com) → profile icon → **My Profile**
2. **API Tokens** → **Create Token** → **Use template** next to **Edit zone DNS**
3. **Zone Resources** → *Include* → *Specific zone* → your domain
4. **Continue to summary** → **Create Token** → copy it now, it won't be shown again

## Step 2: Get Your Zone ID and DNS Record ID

**Zone ID**: Cloudflare dashboard → your domain → **Overview** → API section in sidebar.

**DNS Record ID** (not visible in UI, retrieve via API):

```bash
curl -s -X GET "https://api.cloudflare.com/client/v4/zones/<ZONE_ID>/dns_records?name=ddns.yourdomain.org" \
  -H "Authorization: Bearer <API_TOKEN>" \
  -H "Content-Type: application/json" | python3 -m json.tool
```

Find `"id"` inside the matching record in the output.

## Step 3: Install nftables

```bash
sudo apt update
sudo apt install nftables -y
sudo systemctl enable nftables
```

## Step 4: Configure the Firewall

The `whitelist` set is intentionally left empty on disk — see Section 20. Static trusted
IPs get their own dedicated rule.

```bash
sudo nano /etc/nftables.conf
```

```
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    set whitelist {
        type ipv4_addr
    }

    chain input {
        type filter hook input priority 0; policy drop;

        iif lo accept
        ct state established,related accept
        ct state invalid drop

        ip protocol icmp icmp type echo-request limit rate 5/second accept
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept

        udp dport 51820 accept

        # DNS — WireGuard clients only
        ip saddr 10.8.0.0/24 udp dport 53 accept
        ip saddr 10.8.0.0/24 tcp dport 53 accept

        # Docker bridge to AdGuard — find bridge name: `ip link show | grep br-`
        iifname "br-<network_id>" tcp dport 3000 accept

        # SSH and HTTPS — dynamic IP via DDNS-managed set
        ip saddr @whitelist tcp dport { <YOUR_SSH_PORT>, 443 } accept

        # SSH only — static IP
        ip saddr <YOUR_STATIC_IP> tcp dport <YOUR_SSH_PORT> accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;

        ct state established,related accept
        ct state invalid drop

        ip saddr <YOUR_STATIC_IP> tcp dport 443 drop

        iifname "wg0" oifname "eth0" accept
        iifname "eth0" oifname "wg0" accept

        meta oifname "docker0" accept
        meta iifname "docker0" accept

        iifname "br-*" accept
        oifname "br-*" accept
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}

table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr 10.8.0.0/24 oifname "eth0" masquerade
        ip saddr 172.16.0.0/12 oifname "eth0" masquerade
    }
}
```

> Ensure console access or another fallback before applying — default input policy is
> DROP and the whitelist set is empty until the DDNS script runs.

Find the Docker bridge for a given network:

```bash
docker network inspect proxy-net --format '{{.Id}}' | cut -c1-12
# then look for br-<that prefix> in: ip link show
```

Apply:

```bash
sudo nft -f /etc/nftables.conf
sudo systemctl start nftables
sudo nft list ruleset
```

## Step 5: Install the DDNS Whitelist Script

```bash
sudo nano /usr/local/bin/update-whitelist-ddns.sh
```

See Section 20 for the full corrected script (with self-healing live-set verification).

```bash
sudo chmod +x /usr/local/bin/update-whitelist-ddns.sh
```

## Step 6: Create the Systemd Service

```bash
sudo nano /etc/systemd/system/nftables-ddns.service
```

```ini
[Unit]
Description=Update nftables whitelist via Cloudflare API
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-whitelist-ddns.sh
```

## Step 7: Create the Systemd Timer

```bash
sudo nano /etc/systemd/system/nftables-ddns.timer
```

```ini
[Unit]
Description=Run DDNS whitelist update every 5 minutes

[Timer]
OnBootSec=15sec
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
```

## Step 8: Enable, Start, and Verify

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now nftables-ddns.timer
systemctl list-timers nftables-ddns.timer
sudo /usr/local/bin/update-whitelist-ddns.sh
cat /run/nftables-ddns.log
sudo nft list set inet filter whitelist
```

A successful first run:

```
[2026-01-01 12:00:00] IP change detected for ddns.yourdomain.org: '(none)' → <YOUR_IP>
[2026-01-01 12:00:00] Added new IP <YOUR_IP> to set 'whitelist'
[2026-01-01 12:00:00] Whitelist update complete.
```

## File Reference

| Path | Purpose |
|---|---|
| `/etc/nftables.conf` | nftables firewall ruleset |
| `/usr/local/bin/update-whitelist-ddns.sh` | DDNS whitelist update script |
| `/etc/systemd/system/nftables-ddns.service` | Systemd service unit |
| `/etc/systemd/system/nftables-ddns.timer` | Systemd timer (every 5 minutes) |
| `/run/nftables-ddns.ip` | State file — last known dynamic IP |
| `/run/nftables-ddns.log` | Runtime log (cleared on reboot) |

## Troubleshooting

| Symptom | Likely Cause | Action |
|---|---|---|
| `HTTP 000` errors in log | DNS broken or network not ready — see Section 18's resolvconf callout | `getent hosts api.cloudflare.com`; check `systemctl status network-online.target` |
| SSH/HTTPS blocked from home | IP changed but whitelist not updated, or set was cleared externally | Check log; run the script manually; confirm with `nft list set inet filter whitelist` |
| `HTTP 401` from Cloudflare | API token expired/revoked | Generate a new token, update `CF_API_TOKEN` |
| `HTTP 403` from Cloudflare | Token lacks DNS read permission | Recreate token with *Zone → DNS → Read* |
| IP updated in nftables but Traefik still blocks | `fileConfig.yml` not reloaded | Check `docker logs traefik`; Traefik watches for file changes automatically |
| Log/state file missing after reboot | `/run` tmpfs cleared — expected, see Section 20 | Normal; regenerates on next timer run |
| Static IP can reach HTTPS after reboot | Whitelist set empty before DDNS script runs | Forward chain drop rule blocks the static IP from Docker-hosted 443 regardless |

---

