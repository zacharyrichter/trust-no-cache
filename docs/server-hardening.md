# Debian 13 Trixie — Server Setup and Hardening Guide

A complete guide for setting up a hardened Debian 13 Trixie VPS with WireGuard, AdGuard
Home, and Docker. Written for a fresh install on a Netcup VPS with a single root partition.

---

## Table of Contents

1. [Initial System Setup](#1-initial-system-setup)
2. [Netcup Filesystem Fix](#2-netcup-filesystem-fix)
3. [User and SSH Hardening](#3-user-and-ssh-hardening)
4. [Firewall with nftables](#4-firewall-with-nftables)
5. [Fail2ban](#5-fail2ban)
6. [Unattended Upgrades](#6-unattended-upgrades)
7. [Kernel Hardening with Sysctl](#7-kernel-hardening-with-sysctl)
8. [Filesystem Mount Hardening](#8-filesystem-mount-hardening)
9. [PAM and Login Hardening](#9-pam-and-login-hardening)
10. [Console Hardening](#10-console-hardening)
11. [System Email with Mailgun](#11-system-email-with-mailgun)
12. [File Integrity with AIDE](#12-file-integrity-with-aide)
13. [Log Monitoring with Logcheck](#13-log-monitoring-with-logcheck)
14. [Package Integrity with debsums](#14-package-integrity-with-debsums)
15. [needrestart](#15-needrestart)
16. [Docker Installation and Hardening](#16-docker-installation-and-hardening)
17. [nftables and Docker Integration](#17-nftables-and-docker-integration)
18. [WireGuard Server](#18-wireguard-server)
19. [AdGuard Home](#19-adguard-home)
20. [DDNS Whitelist Updater](#20-ddns-whitelist-updater)
21. [Post-Reboot Verification](#21-post-reboot-verification)
22. [Operational Procedures](#22-operational-procedures)

**Companion guides** (full setup detail for items referenced above, in this same
`docs/` directory):
- [Firewall & Dynamic IP Whitelist](firewall-ddns.md)
- [Mailgun System Email](mailgun-relay.md)
- [AIDE, Logcheck & Logdy Monitoring](monitoring-aide-logcheck-logdy.md)
- [Docker Compose Auto-Update](docker-auto-update.md)

---

## 1. Initial System Setup

Update the system fully before doing anything else.

```bash
apt update && apt full-upgrade -y
apt autoremove -y && apt autoclean
apt install bsdextrautils -y
```

Remove packages that are not needed on a VPS.

```bash
apt remove --purge laptop-detect installation-report os-prober tasksel task-english cloud-init cloud-guest-utils ufw qemu-guest-agent -y
apt autoremove --purge -y
```

> NOTE: `qemu-guest-agent` provides the hypervisor a reporting and control channel into the
> guest VM. On Netcup it is installed by default but is not required for normal VPS
> operation. Removing it may prevent clean snapshots via the Netcup SCP panel — test a
> snapshot after removal if you rely on this feature.

> **Before removing any package during future maintenance passes** (fleet-wide cleanups,
> `apt autoremove`, etc.), check whether it's a dependency of something that only fails
> silently or on next boot — not immediately. See Section 18's callout on `resolvconf`
> for a concrete example of this failure mode and how to check for it in advance.

---

## 2. Netcup Filesystem Fix

Netcup provisions VPS instances with `maximum mount count: 1` and `errors=remount-ro` in
fstab. This causes the root filesystem to mount read-only on boot when orphaned inodes are
present, which prevents Docker — and in practice any service doing disk writes at boot —
from starting cleanly.

Applied early, before later sections perform live config edits and installs that assume a
read-write root.

### Fix 1 — Change fstab error behavior

Edit `/etc/fstab` and change the root partition line from:

```
UUID=... / ext4 errors=remount-ro 0 1
```

To:

```
UUID=... / ext4 errors=continue 0 1
```

> **Note:** `/etc/fstab` is edited again in Section 8 (Filesystem Mount Hardening) to add
> `/tmp` and `/dev/shm` hardening entries. These are separate, additive changes to the
> same file — the root partition line changed here is not touched again in Section 8.

### Fix 2 — Increase mount count threshold

```bash
tune2fs -c 30 -i 1m /dev/vda4
```

Verify:

```bash
tune2fs -l /dev/vda4 | grep -E 'state|count|interval'
```

### Fix 3 — Docker wait-for-rw override

Even with the above fixes, Docker may start before the filesystem is fully read-write. Add
this override once Docker is installed (Section 16). It polls the mount state before
starting dockerd:

Create `/etc/systemd/system/docker.service.d/wait-for-rw.conf`:

```ini
[Unit]
After=local-fs.target
Requires=local-fs.target

[Service]
ExecStartPre=/bin/sh -c 'until mount | grep "on / " | grep -q "rw"; do sleep 1; done'
```

```bash
systemctl daemon-reload
systemctl restart docker
```

If Docker ever fails with `read-only file system`, remount manually and start Docker:

```bash
mount -o remount,rw /
systemctl start docker
```

---

## 3. User and SSH Hardening

### Create a non-root user

```bash
adduser youruser
usermod -aG sudo youruser
```

### Copy your SSH public key from your local machine

```bash
ssh-copy-id youruser@your-server-ip
```

### Harden sshd_config

Edit `/etc/ssh/sshd_config` and set the following:

```
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AllowUsers youruser
Port 17010
AddressFamily inet
ClientAliveInterval 300
ClientAliveCountMax 2
```

```bash
systemctl restart sshd
```

Keep your existing session open and verify you can connect in a second terminal before
closing the first.

---

## 4. Firewall with nftables

The firewall configuration for this server — including the whitelist set, WireGuard and
Docker forwarding rules, NAT masquerade, and DDNS integration — is covered in full by
[`firewall-ddns.md`](firewall-ddns.md).

### Quick reference

Install and enable nftables, then apply the ruleset from the firewall guide:

```bash
apt install nftables -y
systemctl enable nftables
nft -f /etc/nftables.conf
systemctl restart nftables
```

Verify the ruleset loaded:

```bash
nft list ruleset
```

> **NOTE:** Default input policy is DROP. The `whitelist` set is intentionally left empty
> in the static config — it's populated at runtime by the DDNS script (Section 20). The
> static IP rule (e.g. `<YOUR_STATIC_IP>`) covers access until that script has run for the
> first time. Have the static IP rule in place or console/KVM access available before
> applying this ruleset for the first time.

---

## 5. Fail2ban

```bash
apt install fail2ban -y
```

Create `/etc/fail2ban/jail.local`:

```ini
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled  = true
port     = 17010
logpath  = %(sshd_log)s
backend  = systemd
```

```bash
systemctl enable --now fail2ban
```

---

## 6. Unattended Upgrades

```bash
apt install unattended-upgrades -y
dpkg-reconfigure --priority=low unattended-upgrades
```

Edit `/etc/apt/apt.conf.d/50unattended-upgrades` and uncomment or set:

```
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::SyslogEnable "true";
Unattended-Upgrade::Automatic-Reboot "false";
```

Allow exec on `/tmp` during apt operations. Create `/etc/apt/apt.conf.d/99tmp-exec`:

```
DPkg::Pre-Invoke  { "mount -o remount,exec /tmp"; };
DPkg::Post-Invoke { "mount -o remount /tmp"; };
```

---

## 7. Kernel Hardening with Sysctl

Create `/etc/sysctl.d/99-hardening.conf`:

```ini
# Reverse path filtering
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0

# SYN flood protection
net.ipv4.tcp_syncookies = 1

# Ignore broadcast pings
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignore bogus ICMP errors
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Log martian packets
net.ipv4.conf.all.log_martians = 1

# Disable Magic SysRq
kernel.sysrq = 0

# Hide kernel pointers
kernel.kptr_restrict = 2

# Restrict dmesg to root
kernel.dmesg_restrict = 1

# ASLR
kernel.randomize_va_space = 2

# Link protections
fs.protected_symlinks = 1
fs.protected_hardlinks = 1

# WireGuard IP forwarding
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
```

Apply:

```bash
sysctl --system
```

---

## 8. Filesystem Mount Hardening

> **Note:** This is the second of two sections that edit `/etc/fstab` — see Section 2 for
> the first (Netcup's `errors=continue` fix on the root partition). The entries below are
> additive and independent of that change.

Edit `/etc/fstab` and add the following lines:

```
tmpfs   /tmp      tmpfs  defaults,nodev,nosuid,noexec  0 0
/tmp    /var/tmp  none   rw,noexec,nosuid,nodev,bind   0 0
tmpfs   /dev/shm  tmpfs  defaults,nodev,nosuid,noexec  0 0
```

Mask the systemd tmp.mount unit to prevent conflict with the fstab entry:

```bash
systemctl mask tmp.mount
systemctl daemon-reload
```

Apply without rebooting:

```bash
mount -o remount /dev/shm
mount tmpfs /tmp -t tmpfs -o defaults,nodev,nosuid,noexec
mount -o bind /tmp /var/tmp
```

Verify:

```bash
mount | grep -E '/tmp|/dev/shm'
```

Test that execution is blocked:

```bash
cp /bin/ls /tmp/test-ls && chmod +x /tmp/test-ls && /tmp/test-ls
rm /tmp/test-ls
```

Expected result: `Permission denied`

---

## 9. PAM and Login Hardening

### login.defs

Edit `/etc/login.defs` and add at the bottom:

```
UMASK           027
FAILLOG_ENAB    yes
```

### limits.conf

Edit `/etc/security/limits.conf` and add at the bottom:

```
* soft nproc 100
* hard nproc 200
* soft nofile 1024
* hard nofile 65536
* soft core 0
* hard core 0
root soft nproc 200
root hard nproc 500
```

### Enable pam_limits

```bash
echo "session required pam_limits.so" | tee -a /etc/pam.d/common-session
```

### System-wide umask

```bash
echo "umask 027" | tee -a /etc/profile
echo "umask 027" | tee -a /etc/skel/.bashrc
echo "umask 027" | tee -a /root/.bashrc
```

### Idle logoff

Create `/etc/profile.d/autologoff.sh`:

```bash
TMOUT=900
readonly TMOUT
export TMOUT
```

```bash
chmod +x /etc/profile.d/autologoff.sh
```

### PATH fix

```bash
echo 'export PATH=$PATH:/sbin:/usr/sbin' >> ~/.bashrc
source ~/.bashrc
```

Log out and back in to verify:

```bash
umask
ulimit -a | grep -E 'processes|open files|core'
```

Expected: umask `0027`, core `0`, max user processes `100`.

---

## 10. Console Hardening

### Lock the root account password

Root cannot log in via SSH due to `PermitRootLogin no`. Locking the password also closes
the console path — emergency and rescue mode targets require `sulogin`, which cannot be
answered with a locked account.

```bash
passwd -l root
```

Verify:

```bash
passwd -S root
```

Expected output begins with `root L` — the `L` indicates locked.

### Disable the serial console

The serial console is not used on a KVM VPS and provides an unnecessary local login
surface.

```bash
systemctl disable --now serial-getty@ttyS0.service
systemctl mask serial-getty@ttyS0.service
```

Verify no serial console entries remain active:

```bash
systemctl list-units 'serial-getty*'
```

Expected: no units listed.

---

## 11. System Email with Mailgun

System tools including AIDE and logcheck send reports and alerts by email. This setup uses
Mailgun as the outbound provider via three lightweight wrapper scripts that replace the
system `sendmail` and `mail` binaries. exim4 is installed for local MTA functionality but
all outbound mail is handled by the wrappers.

Full setup instructions are in [`mailgun-relay.md`](mailgun-relay.md). Complete that guide before proceeding to
Sections 12 and 13.

### Dependencies introduced by this section

| Component | Purpose |
|---|---|
| `/usr/local/bin/sendmail` | Used by logcheck, cron, and system tools |
| `/usr/local/bin/mail` | Used by AIDE |
| `/usr/local/bin/mailgun-send` | General-purpose script sender |
| `exim4` | Local MTA (loopback only) |
| `/etc/aliases` | Routes root and logcheck mail to a real address |
| `/etc/mailname` | Mail hostname |

---

## 12. File Integrity with AIDE

AIDE monitors the filesystem for unexpected changes and emails a daily report. The apt
post-invoke hook keeps the database current after package operations automatically.

Full setup instructions are in [`monitoring-aide-logcheck-logdy.md`](monitoring-aide-logcheck-logdy.md). That guide covers installation,
configuration, exclusions, database initialisation, the systemd timer, the apt hook, and
email delivery.

### Manual database update

Run this after any manual system changes such as editing config files:

```bash
sudo aide --update --config /etc/aide/aide.conf
sudo cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

---

## 13. Log Monitoring with Logcheck

Logcheck scans system logs hourly and emails a filtered report of security events, service
failures, and anomalies. Custom ignore rules suppress known-benign Docker and system noise.

Full setup instructions are in [`monitoring-aide-logcheck-logdy.md`](monitoring-aide-logcheck-logdy.md).

---

## 14. Package Integrity with debsums

```bash
apt install debsums -y
```

Edit `/etc/default/debsums` and set:

```
CRON_CHECK="weekly"
```

Run a manual check to verify the baseline is clean:

```bash
debsums --silent
```

No output means all package files are intact.

---

## 15. needrestart

```bash
apt install needrestart -y
```

Edit `/etc/needrestart/needrestart.conf` and set:

```
$nrconf{restart} = 'a';
```

This automatically restarts services after upgrades without prompting.

---

## 16. Docker Installation and Hardening

### Install Docker from the official repository

```bash
apt install ca-certificates curl -y
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update
apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
```

### daemon.json

Create `/etc/docker/daemon.json`:

```json
{
  "firewall-backend": "nftables",
  "userland-proxy": false,
  "no-new-privileges": true,
  "live-restore": true,
  "log-driver": "journald",
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 64000,
      "Soft": 64000
    }
  }
}
```

### Docker systemd override for read-only filesystem issue (Netcup specific)

See Section 2, Fix 3 for the wait-for-rw override. Apply it now that Docker is installed.

### Unmask tmp.mount if Docker fails to start

If Docker fails with `Unit tmp.mount is masked`:

```bash
systemctl unmask tmp.mount
systemctl daemon-reload
systemctl start docker
```

### Boot ordering with WireGuard

Docker must not start until `wg-quick@wg0` is up, since AdGuard (Section 19) binds to the
WireGuard interface address for its DNS listener. See Section 18's "Boot ordering with
Docker" for the required systemd override — apply it once both Docker and WireGuard are
installed.

---

## 17. nftables and Docker Integration

Docker 29 supports native nftables via the `firewall-backend: nftables` setting in
`daemon.json`. This creates a separate `docker-bridges` table and does not inject rules
into the `inet filter` table.

After starting Docker, verify clean coexistence:

```bash
nft list ruleset | grep -E 'Warning|docker|inet'
```

Expected output shows `table inet filter` and `table ip docker-bridges` with no
iptables-nft warnings.

The `forward` chain in `inet filter` allows all Docker bridge traffic using wildcard
interface matching and covers the full RFC 1918 `172.16.0.0/12` range used by Docker
bridge networks via NAT masquerade:

```nft
chain forward {
    type filter hook forward priority 0; policy drop;

    ct state established,related accept
    ct state invalid drop

    # Default Docker bridge
    meta oifname "docker0" accept
    meta iifname "docker0" accept

    # WireGuard forwarding
    iifname "wg0" oifname "eth0" accept
    iifname "eth0" oifname "wg0" accept

    # All Docker bridge networks (covers dynamically named br-* interfaces)
    iifname "br-*" accept
    oifname "br-*" accept
}
```

The NAT postrouting chain masquerades both WireGuard and Docker traffic:

```nft
table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr 10.8.0.0/24 oifname "eth0" masquerade
        ip saddr 172.16.0.0/12 oifname "eth0" masquerade
    }
}
```

The `172.16.0.0/12` range covers all Docker bridge subnets (`172.17.0.0/16` through
`172.31.0.0/16`) without needing per-network rules. When adding new Docker bridge networks
no additional nftables changes are required.

---

## 18. WireGuard Server

### Install

```bash
apt install wireguard wireguard-tools resolvconf -y
```

> **CRITICAL DEPENDENCY:** `resolvconf` is required by `wg-quick`'s PostUp/PreDown hooks
> whenever `DNS =` is set in `[Interface]` (as below). Removing it — e.g. during a package
> cleanup where it looks like unused cruft — causes `wg-quick@wg0` to fail on next start
> with exit 127 ("command not found").
>
> Cascade in this stack: WireGuard fails → AdGuard (Section 19) can't bind to
> `10.8.0.1:53`, crash-loops → DNS breaks host-wide → DDNS timer (Section 20) fails with
> HTTP 000 (can't resolve `api.cloudflare.com`) → if the whitelist set was also cleared by
> the reboot, SSH access is lost, requiring console/KVM to recover.
>
> Check before removing any package fleet-wide:
> ```bash
> dpkg -L resolvconf | grep -i wg
> journalctl -u wg-quick@wg0 --since "-30 days" | grep -i resolvconf
> ```

### Generate server keys

```bash
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard
bash -c 'wg genkey > /etc/wireguard/server.key'
bash -c 'wg pubkey < /etc/wireguard/server.key > /etc/wireguard/server.pub'
chmod 600 /etc/wireguard/server.key
chmod 644 /etc/wireguard/server.pub
```

### Server configuration

Create `/etc/wireguard/wg0.conf`:

```ini
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = <contents of /etc/wireguard/server.key>
DNS = 10.8.0.1
```

Add client peers below as they are created:

```ini
[Peer]
# device-name
PublicKey = <client public key>
AllowedIPs = 10.8.0.x/32
```

Set permissions:

```bash
chmod 600 /etc/wireguard/wg0.conf
```

### Enable and start

```bash
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
wg show
```

### Boot ordering with Docker

Docker (Section 16) and AdGuard (Section 19) must not start until wg0 is up, since
AdGuard binds to wg0's address for DNS. Enforce this explicitly rather than relying on
default systemd parallelization:

```bash
systemctl edit docker.service
```

Add:

```ini
[Unit]
After=wg-quick@wg0.service
Wants=wg-quick@wg0.service
```

```bash
systemctl daemon-reload
```

Without this, Docker and WireGuard start in parallel with no guaranteed order, and a slow
or failed WireGuard start produces an AdGuard crash loop that looks like an AdGuard
problem but isn't.

### Adding a client

Generate a keypair for the client:

```bash
bash -c 'wg genkey > /etc/wireguard/clientname.key'
bash -c 'wg pubkey < /etc/wireguard/clientname.key > /etc/wireguard/clientname.pub'
chmod 600 /etc/wireguard/clientname.key
chmod 644 /etc/wireguard/clientname.pub
```

Add the peer to `wg0.conf`:

```ini
[Peer]
# clientname
PublicKey = <contents of clientname.pub>
AllowedIPs = 10.8.0.x/32
```

Reload without dropping connections:

```bash
wg-quick strip wg0 > /tmp/wg0-stripped.conf
wg syncconf wg0 /tmp/wg0-stripped.conf
rm /tmp/wg0-stripped.conf
```

Create the client config file at `/etc/wireguard/clientname.conf`:

```ini
[Interface]
PrivateKey = <contents of clientname.key>
Address = 10.8.0.x/24
DNS = 10.8.0.1

[Peer]
PublicKey = <contents of server.pub>
Endpoint = your-server-ip:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

Generate a QR code for mobile devices:

```bash
apt install qrencode -y
qrencode -t ansiutf8 -r /etc/wireguard/clientname.conf
```

### Client IP assignment

| Device | IP |
|---|---|
| Server | 10.8.0.1 |
| Client 1 | 10.8.0.2 |
| Client 2 | 10.8.0.3 |
| Client 3 | 10.8.0.4 |
| Client 4 | 10.8.0.5 |

---

## 19. AdGuard Home

AdGuard Home runs as a Docker container with `network_mode: host` so it can bind directly
to port 53 on the host's WireGuard interface.

> **Ordering dependency:** AdGuard binds to `10.8.0.1` (the WireGuard interface) for DNS,
> so it depends on `wg-quick@wg0` starting first. See Section 18's "Boot ordering with
> Docker" for the required systemd override. Without it, AdGuard crash-loops with
> `bind: cannot assign requested address`.

### Directory structure

```bash
mkdir -p /opt/appdata/adguard/{config,work}
chown -R 999:999 /opt/appdata/adguard/config /opt/appdata/adguard/work
chmod -R 755 /opt/appdata/adguard/config /opt/appdata/adguard/work
```

### Compose file

Create `/opt/appdata/adguard/compose.yaml`:

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
      - no-new-privileges:true
```

### Start

```bash
cd /opt/appdata/adguard
docker compose up -d
docker compose logs --tail 10
```

### Initial setup

The setup wizard runs on port 3000. Access it at `http://your-server-ip:3000`. Configure
as follows:

- Admin interface: all interfaces, port 3000
- DNS server: all interfaces, port 53

After completing the wizard, port 3000 is locked to whitelisted IPs only via the nftables
whitelist set (already configured in Section 4).

### DNS settings

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

Fallback DNS servers:

```
9.9.9.9
194.242.2.2
```

Additional settings:

- Upstream DNS mode: Parallel
- DNSSEC: enabled
- Disable resolving of IPv6 addresses: enabled (if WireGuard tunnel is IPv4 only)
- Optimistic caching: enabled
- EDNS Client Subnet: disabled
- Rate limit: 0 (disabled — safe for private WireGuard-only DNS)

### Recommended blocklists

Add via Filters > Blocklists > Add blocklist:

| Name | URL |
|---|---|
| AdGuard DNS filter | https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt |
| HaGeZi Multi Pro | https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/multi.txt |
| HaGeZi Threat Intelligence | https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/tif.txt |
| OISD Big | https://big.oisd.nl/domainswild |
| Steven Black Unified | https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts |
| HaGeZi Adult | https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/porn-mini.txt |
| HaGeZi Tracking | https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/native.combined.txt |
| EasyPrivacy | https://v.firebog.net/hosts/Easyprivacy.txt |

### Client profiles

Add clients under Settings > Client settings. Assign each WireGuard device by IP and
configure per-device filtering rules. Global settings should be permissive with stricter
rules applied at the client profile level.

---

## 20. DDNS Whitelist Updater

The DDNS updater keeps the nftables whitelist in sync with your dynamic home IP by reading
the current IP from a Cloudflare DNS A record every 5 minutes. It also updates Traefik's
`ipAllowList` config when the IP changes.

Full setup instructions including Cloudflare API token creation and DNS record ID retrieval
are in [`firewall-ddns.md`](firewall-ddns.md).

### Quick reference

| File | Purpose |
|---|---|
| `/usr/local/bin/update-whitelist-ddns.sh` | Main updater script |
| `/etc/systemd/system/nftables-ddns.service` | Systemd service unit |
| `/etc/systemd/system/nftables-ddns.timer` | Runs every 5 minutes |
| `/run/nftables-ddns.ip` | State file — last known dynamic IP (cleared on reboot) |
| `/run/nftables-ddns.log` | Runtime log (cleared on reboot) |

Enable the timer after completing the firewall guide:

```bash
systemctl enable --now nftables-ddns.timer
```

### Why the state file lives on tmpfs — and why the whitelist is empty on disk

Both are intentional. The `whitelist` set is left **empty** in `/etc/nftables.conf`
(Section 4) rather than baking in a dynamic IP that may be stale after a reboot.
Cloudflare's DNS record is the source of truth on every boot: the timer fires 15 seconds
after boot and repopulates the set fresh. The state file living on tmpfs enforces this —
if it persisted across reboots, the script's change-detection (`NEW_IP == OLD_IP → skip`)
could falsely believe the set is already populated when a reboot just cleared it.

For the same reason, the script's self-healing check verifies live set membership on
every run, not just the state file — the state file only tracks "did the IP change,"
not "is it actually enforced right now." In production, a manual `nft` command cleared
the set without changing the state file; the script logged a stale success and skipped
re-verifying, leaving the set empty for over an hour. The corrected script below closes
that gap.

> If DNS is broken at boot (see Section 18's `resolvconf` callout), the script fails with
> HTTP 000 and retries every 5 minutes until DNS recovers. The static IP rule (Section 4)
> is the fallback during that window.

### Corrected script

```bash
#!/bin/bash
# =============================================================================
# nftables whitelist updater — Cloudflare API edition
# =============================================================================

# --- Configuration -----------------------------------------------------------
CF_API_TOKEN="<YOUR_API_TOKEN>"
CF_ZONE_ID="<YOUR_ZONE_ID>"
CF_RECORD_ID="<YOUR_RECORD_ID>"
CF_RECORD_NAME="ddns.yourdomain.org"
NFT_TABLE="inet filter"
NFT_SET="whitelist"
STATE_FILE="/run/nftables-ddns.ip"
LOG_FILE="/run/nftables-ddns.log"
# -----------------------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

HTTP_CODE=$(curl -s -o /run/cf_response.json -w "%{http_code}" \
    -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${CF_RECORD_ID}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json")

if [[ "$HTTP_CODE" != "200" ]]; then
    log "ERROR: Cloudflare API returned HTTP $HTTP_CODE — aborting"
    cat /run/cf_response.json >> "$LOG_FILE"
    exit 1
fi

CF_SUCCESS=$(python3 -c "import json; d=json.load(open('/run/cf_response.json')); print(d.get('success', False))")
if [[ "$CF_SUCCESS" != "True" ]]; then
    log "ERROR: Cloudflare API reported failure:"
    cat /run/cf_response.json >> "$LOG_FILE"
    exit 1
fi

NEW_IP=$(python3 -c "import json; d=json.load(open('/run/cf_response.json')); print(d['result']['content'])")
if [[ ! "$NEW_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log "ERROR: Parsed IP looks invalid: '$NEW_IP' — aborting"
    exit 1
fi

OLD_IP=$(cat "$STATE_FILE" 2>/dev/null)

# Verify the current IP is actually present in the live nftables set — do not
# trust the state file alone. See "Why the state file lives on tmpfs" above.
CURRENT_IN_SET=$(nft list set "$NFT_TABLE" "$NFT_SET" 2>/dev/null | grep -c -F "$NEW_IP")

if [[ "$NEW_IP" == "$OLD_IP" && "$CURRENT_IN_SET" -gt 0 ]]; then
    exit 0
fi

if [[ "$NEW_IP" != "$OLD_IP" ]]; then
    log "IP change detected for $CF_RECORD_NAME: ${OLD_IP:-'(none)'} → $NEW_IP"
else
    log "IP unchanged; whitelist set was missing it — re-adding $NEW_IP"
fi

if [[ -n "$OLD_IP" && "$OLD_IP" != "$NEW_IP" ]]; then
    if nft delete element "$NFT_TABLE" "$NFT_SET" "{ $OLD_IP }" 2>/dev/null; then
        log "Removed old IP $OLD_IP from set '$NFT_SET'"
    else
        log "WARNING: Could not remove old IP $OLD_IP (may not exist in set — continuing)"
    fi
fi

if nft add element "$NFT_TABLE" "$NFT_SET" "{ $NEW_IP }" 2>/dev/null; then
    log "Added new IP $NEW_IP to set '$NFT_SET'"
    echo "$NEW_IP" > "$STATE_FILE"
else
    log "ERROR: Failed to add $NEW_IP to nftables — manual intervention needed"
    exit 1
fi

# --- Update Traefik ipAllowList ---------------------------------------------
TRAEFIK_CONFIG="/opt/appdata/traefik/config/fileConfig.yml"
if [[ "$NEW_IP" != "$OLD_IP" ]]; then
    if [[ -n "$OLD_IP" ]]; then
        sed -i "s|${OLD_IP}/32|${NEW_IP}/32|g" "$TRAEFIK_CONFIG"
        log "Updated Traefik ipAllowList: ${OLD_IP}/32 → ${NEW_IP}/32"
    else
        if ! grep -qF "${NEW_IP}/32" "$TRAEFIK_CONFIG"; then
            sed -i "/ipAllowList:/,/sourceRange:/{/sourceRange:/a\\          - \"${NEW_IP}/32\"}" "$TRAEFIK_CONFIG"
            log "Added ${NEW_IP}/32 to Traefik ipAllowList"
        fi
    fi
fi

log "Whitelist update complete."
```

> The log distinguishes a genuine IP change from a re-add of an unchanged IP
> (`"whitelist set was missing it — re-adding"`) — useful when reading
> `/run/nftables-ddns.log` after an incident.

Make the script executable:

```bash
sudo chmod +x /usr/local/bin/update-whitelist-ddns.sh
```

---

## 21. Post-Reboot Verification

Run these checks after every reboot to confirm all services are running correctly.

```bash
# Filesystem is read-write
mount | grep ' / '

# All critical services running
systemctl status nftables wg-quick@wg0 docker fail2ban

# Docker and containers running
docker ps

# WireGuard tunnel active
wg show

# nftables ruleset loaded AND whitelist set actually populated (not just present)
nft list ruleset | grep -E 'table|whitelist'
nft list set inet filter whitelist

# All timers active and scheduled
systemctl list-timers | grep -E 'apt|aide|ddns|logcheck'
```

Expected state:

- Root filesystem mounted `rw`
- nftables, wg-quick, docker, fail2ban all active
- AdGuard container running
- WireGuard interface up with peers listed
- `nft list set inet filter whitelist` shows `elements = { <your current IP> }` — a
  service showing "active" doesn't guarantee the set is actually populated.
- `dailyaidecheck.timer`, `apt-daily-upgrade.timer`, `nftables-ddns.timer`, and
  `logcheck.timer` all scheduled

---

## 22. Operational Procedures

### After any manual config file change

```bash
sudo aide --update --config /etc/aide/aide.conf
sudo cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

### After apt install or apt upgrade

The `DPkg::Post-Invoke` hook in `/etc/apt/apt.conf.d/99-post-upgrade-hook` handles AIDE
database updates automatically. No manual action needed.

### Nightly Docker Compose updates

A separate timer (`docker-update.timer`) handles unattended nightly updates of Docker
Compose projects, independent of the OS-level `unattended-upgrades` covered in Section 6.
See [`docker-auto-update.md`](docker-auto-update.md) for the full script, systemd units, and AIDE-exit-code handling.

### Before removing any package fleet-wide

Check for dependents that only fail on next boot/restart, not immediately — `resolvconf`
(Section 18) is the concrete example: looked unused, but `wg-quick` called it internally,
and removing it caused a cascading outage that only surfaced on next reboot.

```bash
# Check if any systemd unit or script on the host references it
grep -rl "<package-or-binary-name>" /etc/systemd/system/ /usr/local/bin/ 2>/dev/null
dpkg -L <package-name>   # see what files/binaries it actually provides
```

### Adding a new WireGuard client

1. Generate keypair in `/etc/wireguard/`
2. Add peer block to `/etc/wireguard/wg0.conf`
3. Run `wg syncconf` to apply without restarting the tunnel
4. Create client config file
5. Add client entry in AdGuard Home with the assigned IP
6. Distribute config via QR code or secure file transfer

### Rotating the Cloudflare API token

1. Generate a new token in Cloudflare Dashboard > My Profile > API Tokens
2. Update the token in `/usr/local/bin/update-whitelist-ddns.sh`
3. Test the script manually: `sudo /usr/local/bin/update-whitelist-ddns.sh`
4. Check the log: `cat /run/nftables-ddns.log`
5. Confirm the set actually contains your IP, not just that the script logged success:
   `sudo nft list set inet filter whitelist`

### Rotating the Mailgun API key

1. Generate a new key in Mailgun Dashboard > Settings > API Keys
2. Update `MAILGUN_API_KEY` in all three scripts:
   - `/usr/local/bin/sendmail`
   - `/usr/local/bin/mail`
   - `/usr/local/bin/mailgun-send`
3. Test delivery: `printf "Subject: test\n\ntest" | sudo /usr/local/bin/sendmail your@email.com`

### Updating the nftables whitelist manually

To add a static IP to the whitelist permanently, edit `/etc/nftables.conf` and add it to
the `elements` block in the whitelist set, then run:

```bash
nft -f /etc/nftables.conf
```

### Checking AdGuard query logs

Access the AdGuard web UI at `http://your-server-ip:3000` from a whitelisted IP. The query
log shows all DNS requests per client with block/allow status.

### Verifying WireGuard client connectivity

```bash
wg show
```

A healthy peer shows a recent handshake timestamp and increasing transfer counters. If a
peer shows no handshake or stale counters, check that the client config has the correct
server public key and endpoint IP.

### Diagnosing an AdGuard crash loop

Check the logs first for the actual bind error before assuming AdGuard itself is broken:

```bash
docker logs adguard --tail 50
```

A `bind: cannot assign requested address` error on `10.8.0.1:53` means WireGuard isn't up
yet — see Section 18's boot-ordering fix. Not an AdGuard problem.

### Diagnosing an SSH lockout

1. Confirm sshd is running and listening on the expected port via console/KVM access:
   `systemctl status ssh` / `ss -tlnp | grep <port>`
2. Confirm the nftables whitelist set actually contains your current IP:
   `nft list set inet filter whitelist`
3. If the set is empty, check whether DNS resolution is working at all — a broken
   resolver will prevent the DDNS script from reaching Cloudflare:
   `getent hosts api.cloudflare.com`
4. If DNS is broken, work backward through Section 18's dependency chain
   (`resolvconf` → `wg-quick` → AdGuard → DNS → DDNS timer) before assuming the firewall
   itself is misconfigured.
5. As an immediate unblock while root-causing, manually add your current IP to the live
   set: `nft add element inet filter whitelist { <your-ip> }`. This does not persist
   across reboots — the DDNS timer will keep managing it going forward once DNS is
   restored.

---

## Service Overview

| Service | Purpose | Management |
|---|---|---|
| nftables | Firewall | `systemctl restart nftables` |
| wg-quick@wg0 | WireGuard VPN | `systemctl restart wg-quick@wg0` |
| docker | Container runtime | `systemctl restart docker` |
| adguard | DNS filtering | `docker compose -f /opt/appdata/adguard/compose.yaml restart` |
| fail2ban | Brute force protection | `systemctl restart fail2ban` |
| exim4 | Local MTA (loopback only) | `systemctl restart exim4` |
| unattended-upgrades | Automatic security updates | `systemctl status unattended-upgrades` |
| dailyaidecheck.timer | File integrity monitoring | `systemctl status dailyaidecheck.timer` |
| logcheck.timer | Log monitoring | `systemctl status logcheck.timer` |
| nftables-ddns.timer | Dynamic IP whitelist updater | `systemctl status nftables-ddns.timer` |
| docker-update.timer | Nightly Compose image updates (see [`docker-auto-update.md`](docker-auto-update.md)) | `systemctl status docker-update.timer` |

---

## File Locations

| File | Purpose |
|---|---|
| `/etc/nftables.conf` | Firewall ruleset |
| `/etc/wireguard/wg0.conf` | WireGuard server config |
| `/etc/wireguard/*.conf` | WireGuard client configs |
| `/etc/docker/daemon.json` | Docker daemon config |
| `/etc/systemd/system/docker.service.d/wait-for-rw.conf` | Netcup read-only-boot workaround |
| `/opt/appdata/adguard/compose.yaml` | AdGuard compose file |
| `/opt/appdata/adguard/config/AdGuardHome.yaml` | AdGuard config |
| `/var/lib/aide/aide.db` | AIDE integrity database |
| `/etc/apt/apt.conf.d/99-post-upgrade-hook` | AIDE post-apt hook |
| `/etc/apt/apt.conf.d/99tmp-exec` | tmp exec hook for apt |
| `/usr/local/bin/update-whitelist-ddns.sh` | DDNS whitelist updater |
| `/run/nftables-ddns.log` | DDNS updater log (cleared on reboot) |
| `/usr/local/bin/sendmail` | Mailgun sendmail wrapper |
| `/usr/local/bin/mail` | Mailgun mail wrapper |
| `/usr/local/bin/mailgun-send` | Mailgun general-purpose sender |
| `/etc/exim4/update-exim4.conf.conf` | exim4 local MTA config |
| `/etc/aliases` | System mail routing |
| `/etc/mailname` | Mail hostname |
| `/etc/logcheck/logcheck.conf` | Logcheck configuration |
| `/etc/logcheck/ignore.d.server/local-docker-noise` | Custom logcheck ignore rules |
| `/etc/profile.d/autologoff.sh` | Idle session timeout |
| `/etc/security/limits.conf` | Resource limits |
| `/etc/sysctl.d/99-hardening.conf` | Kernel hardening parameters |

---

