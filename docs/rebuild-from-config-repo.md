# Config copy and rebuild

How I keep enough of this host's configuration to rebuild it on a fresh Debian install, without ever giving the host a way into my home network.

## The principle

The VPS is the least trusted machine I run: it accepts traffic from the internet. So the copy of its configuration is **pulled by a workstation at home**, over SSH, by hand. The VPS never connects out to the repo, and it holds no credentials for anything at home. If the VPS were compromised, the configuration backup would not be a path back.

The cost is that the copy is only as fresh as the last time I refreshed it. The host is the source of truth; the repo is a copy.

## What the private `vps` repo holds

It is a private repository (this public repo holds the sanitized configs only, in [`configs/`](../configs/)). It has two parts:

| Part | Contents |
|---|---|
| `<service>/` | One folder per service, laid out as under `/opt/appdata/`: the compose file, the service's `.env`, and its config (Traefik's two YAML files and password file, AdGuard Home's config, ntfy's `server.yml`) |
| `host/` | Host files laid out as on the host's filesystem (`host/etc/...`, `host/opt/...`, `host/usr/local/...`, `host/home/...`): scripts, systemd units and timers, Docker's `daemon.json` and start-order drop-ins, `nftables.conf`, sshd config, `authorized_keys`, sysctl files, audit rules, apt, debsums and logrotate config, `fstab` |

**Not in the repo, on purpose:**

- Service data: databases, accounts, certificates and logs.
- Host secrets: `/etc/wireguard/` (server key and peers), `/etc/nftables-ddns.env` (Cloudflare token) and `/etc/ntfy-sendmail.env` (ntfy token). Each can be recreated during a rebuild, which is a better trade than storing it.

The per-service `.env` files **are** in the private repo and do contain secrets, which is why that repo is private and why nothing from it is published here.

## Refreshing the copy

Do this after changing anything on the VPS. On the VPS, build two archives:

```bash
sudo tar -czf /home/admin/vps-config.tar.gz -C /opt/appdata \
  adguard/compose.yaml adguard/config/AdGuardHome.yaml \
  freshrss/compose.yaml \
  ntfy/compose.yaml ntfy/server.yml \
  traefik/compose.yaml traefik/.env traefik/config/traefik.yml \
  traefik/config/fileConfig.yml traefik/config/adguard.htpasswd

sudo tar -czf /home/admin/vps-host.tar.gz -C / \
  opt/docker-update.sh opt/scripts \
  usr/local/bin/ntfy-sendmail usr/local/bin/update-whitelist-ddns.sh usr/local/sbin/strip-nullok \
  etc/systemd/system/docker-update.service etc/systemd/system/docker-update.timer \
  etc/systemd/system/integrity-check.service etc/systemd/system/integrity-check.timer \
  etc/systemd/system/nftables-ddns.service etc/systemd/system/nftables-ddns.timer \
  etc/systemd/system/docker.service.d \
  etc/nftables.conf etc/docker/daemon.json etc/fstab \
  etc/ssh/sshd_config etc/ssh/sshd_config.d/00-hardening.conf home/admin/.ssh/authorized_keys \
  etc/sysctl.conf etc/sysctl.d etc/audit/rules.d \
  etc/security/faillock.conf etc/sudoers.d/cis_defaults etc/profile.d/autologoff.sh etc/issue.net \
  etc/apt/apt.conf.d/20auto-upgrades etc/apt/apt.conf.d/50unattended-upgrades \
  etc/apt/apt.conf.d/51unattended-upgrades-mail etc/apt/apt.conf.d/99-strip-nullok \
  etc/debsums-ignore etc/default/debsums etc/logrotate.d/traefik

sudo chown admin:admin /home/admin/vps-config.tar.gz /home/admin/vps-host.tar.gz
chmod 600 /home/admin/vps-config.tar.gz /home/admin/vps-host.tar.gz
```

On the workstation, pull, unpack and delete:

```bash
scp vps:vps-config.tar.gz vps:vps-host.tar.gz ~/
mkdir -p ~/vps-repo/host
tar -xzf ~/vps-config.tar.gz -C ~/vps-repo
tar -xzf ~/vps-host.tar.gz -C ~/vps-repo/host
rm ~/vps-config.tar.gz ~/vps-host.tar.gz
```

Back on the VPS, `rm /home/admin/vps-config.tar.gz /home/admin/vps-host.tar.gz`, then commit `~/vps-repo` to the private repo. The archives are mode 600 and exist only for the length of the transfer. When a service or a host file is added, its path goes into the lists above.

## What a rebuild does not bring back

| Lost | Effect |
|---|---|
| FreshRSS `data/` | Feeds, read state and the account are set up again |
| ntfy `data/auth.db` | Accounts, access rules and tokens are recreated; phones sign in again |
| AdGuard Home `work/` | Query log and statistics start empty. Settings come back from `AdGuardHome.yaml` as of the last copy |
| Traefik `acme.json` | A new certificate is issued automatically at first start |
| WireGuard keys | A new server key, and every device is enrolled again |
| Cloudflare and ntfy tokens | New ones are created |

Service data is not backed up. The config copy covers rebuilding the host, not restoring its data.

## Rebuilding

The order matters in three places: **sshd before the firewall, the firewall before Docker, and WireGuard before Docker.** Keep the provider's web console open for the whole rebuild.

### 1. Base system and access

1. Install Debian from the provider's control panel and create the admin user with `sudo`.
2. From the workstation, copy the repo to the VPS with `scp -r ~/vps-repo`.
3. Install `host/home/admin/.ssh/authorized_keys` as `~admin/.ssh/authorized_keys` (mode 600, directory 700).
4. Install `host/etc/ssh/sshd_config`, `sshd_config.d/00-hardening.conf` and `host/etc/issue.net`. Run `sudo sshd -t`, then `sudo systemctl reload ssh`. SSH is now on its non-default port with hardware keys only. Log in from a **new** session with a hardware key before closing the old one.

### 2. Packages

```bash
sudo apt install apache2-utils apparmor-utils auditd bind9-dnsutils cracklib-runtime \
  curl debsums htop libpam-pwquality mtr nano needrestart nftables \
  python3 python3-yaml qrencode resolvconf tcpdump traceroute \
  unattended-upgrades wireguard wireguard-tools
```

Do **not** install Docker yet (step 6). Do not drop `resolvconf` either: `wg-quick`'s DNS hooks call it, and removing it once cost this host its tunnel (see the [postmortem](postmortem-cascading-dns-failure.md)).

Host DNS: add `nameserver 9.9.9.9` to `/etc/resolvconf/resolv.conf.d/head`, run `sudo resolvconf -u`, and check that `/etc/resolv.conf` shows it. The host resolves through a public resolver and never through AdGuard.

### 3. Host configuration and hardening

From `host/etc/`, install:

- `sysctl.conf` and `sysctl.d/`, then `sudo sysctl --system`.
- `audit/rules.d/`, then `sudo augenrules --load`.
- `security/faillock.conf` and `profile.d/autologoff.sh`.
- `sudoers.d/cis_defaults` (mode 440; check with `sudo visudo -c`).
- `apt/apt.conf.d/` (four files), `debsums-ignore`, `default/debsums` and `logrotate.d/traefik`.

**`fstab` is a reference, not a file to copy.** A new install has different disk identifiers. Carry over only the mount options described in [vps-host-hardening.md](vps-host-hardening.md#filesystem).

The rest of the hardening is not held as files: the PAM settings, the `su` restriction, `login.defs` and the locked root password. Apply the adapted CIS baseline by hand from the fleet's [baseline playbook](https://github.com/zacharyrichter/diff-is-the-audit/blob/main/playbooks/cis-baseline.yml) (documented in [cis-baseline.md](https://github.com/zacharyrichter/diff-is-the-audit/blob/main/docs/cis-baseline.md)), with this host's exceptions as listed in [vps-host-hardening.md](vps-host-hardening.md).

### 4. Firewall and the home-IP allowlist

**Do this step from the provider's console.** Once the firewall loads, SSH is allowed only from the allowlist, which starts empty.

1. Create a new read-only Cloudflare token and `/etc/nftables-ddns.env` ([firewall-and-ddns-allowlist.md](firewall-and-ddns-allowlist.md), steps 1 to 3).
2. Install `host/etc/nftables.conf`, the script and the two units:

   | From `host/` | Mode |
   |---|---|
   | `usr/local/bin/update-whitelist-ddns.sh` | root, 700 |
   | `etc/systemd/system/nftables-ddns.service`, `.timer` | root, 644 |

3. Load the firewall and fill the allowlist straight away:

   ```bash
   sudo nft -c -f /etc/nftables.conf && sudo nft -f /etc/nftables.conf
   sudo systemctl enable nftables
   sudo systemctl daemon-reload
   sudo systemctl enable --now nftables-ddns.timer
   sudo /usr/local/bin/update-whitelist-ddns.sh
   sudo nft list set inet filter whitelist
   ```

   The home IP must appear in the set before you leave the console. The script reports that it can't update Traefik's file at this point; the file is put in place in step 7.

### 5. WireGuard

WireGuard must be up before Docker starts, because AdGuard binds its DNS to the tunnel address.

```bash
sudo -i
umask 077
cd /etc/wireguard
wg genkey | tee server.key | wg pubkey > server.pub
cat > wg0.conf <<EOF
[Interface]
Address = 10.77.0.1/24
ListenPort = 51820
PrivateKey = $(cat server.key)
EOF
systemctl enable --now wg-quick@wg0
wg show wg0
exit
```

Devices are enrolled in step 9.

### 6. Docker

1. Install `host/etc/docker/daemon.json` and the three files in `host/etc/systemd/system/docker.service.d/` **before** installing Docker, so its first start already uses them.
2. Add Docker's apt repository (`/etc/apt/sources.list.d/docker.list`) and install `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`.
3. Create the one network that is made by hand:

   ```bash
   sudo docker network create --subnet 172.18.0.0/16 --gateway 172.18.0.1 warpconduit
   ```

### 7. Services

1. Copy each service folder from the repo to `/opt/appdata/<service>/`.
2. Create each service's data folders. ntfy's `data/` must be writable by uid 1000.
3. Start Traefik first, then the rest, with `sudo docker compose up -d` in each folder.
4. Run `sudo /usr/local/bin/update-whitelist-ddns.sh` again so Traefik's `ipAllowList` holds the current home IP.
5. Per service:
   - **ntfy:** recreate the account, access rules and a token with the `ntfy user`, `ntfy access` and `ntfy token` commands inside the container ([push-alerts-ntfy.md](services/push-alerts-ntfy.md)). Write the URL and token to `/etc/ntfy-sendmail.env` (root, 600) as `NTFY_URL` and `NTFY_TOKEN`.
   - **FreshRSS:** run its first-time setup, create the account, and add the feeds again.
   - **AdGuard Home:** nothing to do. Allow-list rules arrive from home at the next sync run.

### 8. Scripts, timers and notifications

| From `host/` | Install as | Mode |
|---|---|---|
| `usr/local/bin/ntfy-sendmail` | same path | root, 755 |
| `usr/local/sbin/strip-nullok` | same path | root, 755 |
| `opt/docker-update.sh` | same path | root, 755 |
| `opt/scripts/docker-update-notify.sh`, `opt/scripts/integrity-check.sh` | same path | root, 750 |
| `etc/systemd/system/docker-update.*`, `integrity-check.*` | same path | root |

```bash
sudo ln -s /usr/local/bin/ntfy-sendmail /usr/sbin/sendmail
sudo systemctl daemon-reload
sudo systemctl enable --now docker-update.timer integrity-check.timer
```

Send a test message with the command in [push-alerts-ntfy.md](services/push-alerts-ntfy.md).

### 9. Devices

Enrol every device again with the add-peer procedure in [vps-host-hardening.md](vps-host-hardening.md#add-a-peer). Reuse the old names and addresses, so AdGuard's per-device settings still apply. For a device that can't scan a QR code, copy the values out of its client config before deleting it.

### 10. Reboot and verify

Reboot with the provider's console available. Then run every check under Verification in [vps-host-hardening.md](vps-host-hardening.md#verification) and the post-reboot checks in [firewall-and-ddns-allowlist.md](firewall-and-ddns-allowlist.md#post-reboot-and-post-change-checks).

On the workstation, the VPS has a new host key: remove the old `known_hosts` entry before connecting.

## If the public IP changes

The address is static, so a reinstall keeps it. If the VPS ever moves to a new address, update:

- the Cloudflare DNS records for the service hostnames,
- the IP filter on the Cloudflare token ([firewall-and-ddns-allowlist.md](firewall-and-ddns-allowlist.md), step 1),
- the `Endpoint` in every device's WireGuard config, and in the add-peer procedure,
- the VPS entry in the workstation's SSH configuration.
