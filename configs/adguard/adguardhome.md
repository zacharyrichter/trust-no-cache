# AdGuard Home Setup Guide

AdGuard Home is a network-wide DNS server and ad blocker. In this stack it runs directly on the host network so it can bind to the standard DNS port (53) and accept queries from any device on the network. Its web interface is exposed through Traefik behind basic authentication.

---

## Prerequisites

- Docker and Docker Compose installed
- Traefik running with the external Docker network and `fileConfig.yml` configured with an `adguard` router and service
- Port 53 (UDP and TCP) available on the host — no other DNS resolver (such as `systemd-resolved`) should be occupying it
- Port 3000 available on the host for the initial setup wizard (used only on first run)

---

## Directory Structure

```
adguard/
  compose.yml
  config/
    AdGuardHome.yaml
  work/
```

The `config/` directory holds the main AdGuard configuration file. The `work/` directory is used by AdGuard for runtime data such as query logs and statistics. Both are created on the host and mounted into the container.

---

## Step 1 - Prepare Host Directories

```bash
mkdir -p adguard/config adguard/work
```

If you already have an `AdGuardHome.yaml` to restore from backup, place it in `adguard/config/` before starting the container. If starting fresh, AdGuard will write its configuration here after the initial setup wizard.

---

## Step 2 - Free Port 53 on the Host

On systems running `systemd-resolved`, port 53 is typically bound by the stub resolver. AdGuard needs exclusive access to this port. To release it:

```bash
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved
```

Then update `/etc/resolv.conf` to point to a working DNS server temporarily (for example, `nameserver 1.1.1.1`) so the host retains DNS resolution while AdGuard is not yet running.

Once AdGuard is running and configured, update `/etc/resolv.conf` to point to `127.0.0.1`.

---

## Step 3 - Review the Compose File

```yaml
services:
  adguard:
    image: adguard/adguardhome:latest
    container_name: adguard
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./config:/opt/adguardhome/conf
      - ./work:/opt/adguardhome/work
    security_opt:
      - no-new-privileges=true
    mem_limit: 1024m
    memswap_limit: 1536m
```

`network_mode: host` means the container shares the host's network stack directly. This is necessary for AdGuard to bind to port 53. Because of this, AdGuard is not on the shared external Docker network — Traefik reaches its web interface at the host's Docker bridge IP on port 3000, as defined in `fileConfig.yml`.

---

## Step 4 - Start AdGuard

```bash
cd adguard/
docker compose up -d
```

---

## Step 5 - Initial Setup Wizard

On first run, AdGuard starts a temporary setup wizard on port 3000. Open a browser and navigate to:

```
http://<your-server-ip>:3000
```

Walk through the wizard to set:

- The admin username and password
- The DNS listen interface and port (bind to `0.0.0.0:53`)
- The web interface port (keep it at 3000)

After the wizard completes, AdGuard writes its configuration to `config/AdGuardHome.yaml` and restarts itself using the final settings.

> If you are restoring from a pre-existing `AdGuardHome.yaml`, the wizard will be skipped and AdGuard will start directly with that configuration.

---

## Step 6 - Verify DNS is Working

From a client on the same network:

```bash
nslookup google.com <your-server-ip>
```

You should receive a response from AdGuard. If not, check that port 53 is open on the host firewall and that `systemd-resolved` is no longer bound to the port:

```bash
ss -tulpn | grep ':53'
```

---

## Traefik Integration

AdGuard's web interface is routed through Traefik using the file provider configuration. Because AdGuard runs in host networking mode, it is not accessible by container name. Instead, Traefik targets the host's Docker bridge IP.

Find your Docker bridge IP:

```bash
docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}'
```

Then set the service URL in `fileConfig.yml`:

```yaml
services:
  adguard:
    loadBalancer:
      servers:
        - url: http://<docker-bridge-ip>:3000
```

The `adguard-auth` middleware in `fileConfig.yml` adds basic authentication in front of the web interface. This means AdGuard's own built-in authentication is supplemented by a second layer at the proxy.

To access the web interface after Traefik is configured:

```
https://adguard.yourdomain.org
```

---

## Recommended DNS Settings

In the AdGuard web UI under Settings > DNS settings:

Upstream DNS servers:

```
https://dns.quad9.net/dns-query
https://base.doh.mullvad.net/dns-query
```

Bootstrap DNS servers:

```
9.9.9.9
194.242.2.2
```

Additional settings:

- Upstream DNS mode: Parallel
- DNSSEC: enabled
- Optimistic caching: enabled
- EDNS Client Subnet: disabled
- Rate limit: 0 (disabled — safe for private WireGuard-only DNS)

## Recommended Blocklists

Add via Filters > Blocklists > Add blocklist:

| Name | URL |
|---|---|
| AdGuard DNS filter | https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt |
| HaGeZi Multi Pro | https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/multi.txt |
| HaGeZi Threat Intelligence | https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/tif.txt |
| OISD Big | https://big.oisd.nl/domainswild |
| Steven Black Unified | https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts |
| HaGeZi Tracking | https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/native.combined.txt |
| EasyPrivacy | https://v.firebog.net/hosts/Easyprivacy.txt |

---

## Resource Limits

```yaml
mem_limit: 1024m
memswap_limit: 1536m
```

AdGuard is given 1 GB of RAM, which is generous for a small network. If you enable extensive query logging or long statistics retention, this limit will help prevent the container from consuming all available memory on the host.

---

## Notes

- Because the container uses `network_mode: host`, there is no Docker network isolation. All ports AdGuard binds to are directly exposed on the host.
- The `security_opt: no-new-privileges=true` flag prevents any process inside the container from gaining elevated privileges.
- `restart: unless-stopped` means the container will restart after a host reboot unless you explicitly stop it with `docker compose stop`.
- Keep `AdGuardHome.yaml` backed up. It contains all your filter lists, DNS rewrites, client settings, and upstream resolver configuration.
