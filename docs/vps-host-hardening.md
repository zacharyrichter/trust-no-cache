# VPS host hardening and operations

The host is a small, always-on Debian machine on the public internet. It is managed by hand on purpose: a server exposed to the internet must never hold credentials or a route into the home network, so it is not part of my Ansible-managed fleet.

The baseline is [the CIS-derived one I use across the fleet](https://github.com/zacharyrichter/diff-is-the-audit/blob/main/docs/cis-baseline.md), **adapted, not copied**: each control was applied by hand and kept only where it fits this host. Every file below is under [`configs/host/`](../configs/host/) in this repo.

**Design rules**

- **Default deny, then open the minimum.** See [firewall-and-ddns-allowlist.md](firewall-and-ddns-allowlist.md).
- **Hardware keys only for SSH.** No passwords, one permitted user.
- **Detection as well as prevention.** Integrity checks, package checksums and an audit trail, with alerts sent to the host's own ntfy.
- **Small and boring beats clever.** Tools I tried and dropped are retired with a reason in [`archive/`](../archive/).

## SSH

`sshd_config.d/00-hardening.conf` holds the hardening. The main `sshd_config` keeps only what the drop-in doesn't set (port, `MaxSessions`, password and keyboard-interactive auth off, PAM, SFTP). I removed duplicate settings from the main file and compared `sshd -T` before and after to prove the effective configuration didn't change.

| Setting | Value |
|---|---|
| Port | non-default (`2222` in this documentation) |
| Authentication | `AuthenticationMethods publickey`; `PasswordAuthentication no`; `KbdInteractiveAuthentication no` |
| Users | `AllowUsers admin`; `PermitRootLogin no` |
| Limits | `MaxAuthTries 3`, `LoginGraceTime 30`, `MaxStartups 5:30:20`, `MaxSessions 2` |
| Keepalive | `ClientAliveInterval 15`, `ClientAliveCountMax 3` |
| Forwarding | Agent, stream-local, X11 and gateway ports off; tunnels off |
| MACs | Encrypt-then-MAC SHA-2 variants only |
| Banner | `/etc/issue.net` |

Keys are FIDO2 resident keys on three hardware tokens (primary, backup, and one that travels). `authorized_keys` holds exactly those three. The travelling key's entry has `verify-required`, so it needs PIN and touch; the two that stay home need touch only.

## Accounts and authentication

| Control | Where | Setting |
|---|---|---|
| root | `passwd -S root` | Password locked |
| Lockout | `/etc/security/faillock.conf` | 5 failures, 15-minute unlock, applies to root too (60 s), audited |
| Password history | `/etc/pam.d/common-password` | `pam_pwhistory remember=24 enforce_for_root` |
| Password quality | `/etc/security/pwquality.conf` | Distribution defaults. Accepted risk: passwords are only used for `sudo`, behind SSH keys and the IP allowlist |
| Empty passwords | `/usr/share/pam-configs/unix` | `nullok` removed |
| nullok guard | `strip-nullok` run from `apt.conf.d/99-strip-nullok` | After every dpkg run, strips `nullok` again if a package update restored it, and logs to syslog |
| `su` | `/etc/pam.d/su` | `pam_wheel use_uid group=sugroup`, group kept empty |
| `sudo` | `sudoers.d/cis_defaults` | Logs to `/var/log/sudo.log`, 15-minute timestamp |
| Idle shells | `profile.d/autologoff.sh` | `TMOUT=900`, read-only |
| New files and homes | `/etc/login.defs` | `UMASK 027`, `HOME_MODE 0700`, `ENCRYPT_METHOD YESCRYPT` |

The nullok guard exists because a routine package upgrade can quietly undo a hardening change. The guard turns that into a self-correcting, logged event, and `/etc/debsums-ignore` lists the one file it legitimately changes so the weekly checksum run stays quiet.

## Kernel and network (sysctl)

| File | Contents |
|---|---|
| `99-hardening.conf` | No ICMP redirects or source routing, SYN cookies, ignore broadcast pings and bogus ICMP errors, log martians, SysRq off, `kptr_restrict 2`, `dmesg_restrict 1`, full ASLR, symlink and hardlink protection, IPv4/IPv6 forwarding (needed for WireGuard and Docker) |
| `99-rpfilter.conf` | Strict reverse-path filtering on the public interface |
| `50-IPv6.conf` | No router advertisements or SLAAC on any interface |

**Why `rp_filter` is not in `99-hardening.conf`.** The kernel uses the higher of `conf.all` and `conf.<interface>`. Setting `all = 2` would loosen the public interface from 1 (strict) to 2 (loose). The distribution's defaults already set every interface except `all` to 2, so the public interface stays strict while `wg0` and the Docker bridges stay loose, which forwarding needs.

## Filesystem

From `/etc/fstab`:

- `/tmp` is tmpfs with `nodev,nosuid,noexec`; `/var/tmp` is bind-mounted from it with the same options; `/dev/shm` is tmpfs with `nodev,nosuid,noexec`.
- `/` mounts with `errors=continue`, part of a workaround for the hosting platform occasionally remounting the root filesystem read-only. A matching systemd drop-in makes Docker wait until `/` is writable again before it starts.

Package installs work with `/tmp` mounted `noexec`, so no exec-remount hook is needed.

## Auditing

auditd loads the package's base settings plus a CIS-derived rule set (`50-cis.rules`). It watches:

- sudoers and the sudo log, and privilege changes (`execve` where uid differs from euid),
- time changes, hostname and network files,
- failed file access (EACCES and EPERM),
- identity and PAM files, permission and ownership changes, mounts,
- logins and sessions, file deletion,
- AppArmor policy, `chcon`, `usermod` and kernel module loading.

The rules are not locked (`auditctl -s` shows `enabled 1`), and no `audit=1` kernel option is set. Both were deliberate: rule changes load with `augenrules --load` instead of needing a reboot.

## Integrity checks

| Check | Schedule | What it does |
|---|---|---|
| `integrity-check.sh` | systemd timer, daily 03:00 (+ up to 5 min) | SHA-256 of every file under `/etc`, `/usr/bin`, `/usr/sbin` and `/boot`, compared with the previous run's manifest. Any difference goes to ntfy and then becomes the new baseline. If the ntfy send fails, the old baseline is kept, so the change is reported again the next day. Runs at `nice 19`, idle I/O, 64 MB memory cap |
| debsums | cron, weekly | Compares installed package files with the packages' own checksums. Output goes to syslog and, through cron mail, to ntfy |
| needrestart | after each apt run | Restarts affected services automatically |

**Limitation:** the integrity baseline lives on the host it checks. A root-level attacker could change both the files and the baseline. These checks are aimed at drift, accidents and careless intruders, not careful ones.

## Updates

**Operating system packages:** unattended-upgrades, daily.

- The release's main, updates and security origins only.
- `MinimalSteps`, removes unused kernels and dependencies, logs to syslog, **no automatic reboot**.
- Reports through `sendmail`, which is a shim that publishes to ntfy (`Mail "ntfy"`, `MailReport "on-change"`).

Packages from third-party apt repositories (for example Docker's) are neither installed nor reported automatically, and nothing reports a pending reboot. That matches my fleet and is a deliberate gap: when I'm on the host I check by hand.

```bash
apt list --upgradable
ls /var/run/reboot-required
```

**Containers:** `docker-update.sh`, systemd timer, daily at 04:00.

- Runs every project under `/opt/appdata/*/` that has a `compose.yaml`.
- Image-based projects: `pull`, then `down` and `up -d` only if a newer image was downloaded.
- Projects with a `build:` key: pull the other images, then rebuild and redeploy every run.
- Then prunes all unused images and the build cache.
- `docker-update-notify.sh` reads only this run's part of the log and sends to ntfy only when something updated or errored.

Images use moving tags, mostly `latest`. Nightly update with a notification is the policy here, because this host is outside the Renovate-managed fleet and can't be given credentials to that pipeline.

## Notifications

All alerts go to the host's own ntfy, so they don't depend on the home network. `/usr/sbin/sendmail` is a symlink to `ntfy-sendmail`, a small script that accepts both `-s subject` and a `Subject:` header, ignores other sendmail flags, caps the body at 3500 bytes (ntfy rejects larger ones), and reads its URL and token from a root-only env file that is not in this repo.

| Sender | Route |
|---|---|
| unattended-upgrades | `sendmail`, Subject header |
| cron output (debsums) | cron mail through `sendmail` |
| docker-update | `sendmail -s` |
| integrity-check | `curl` straight to ntfy, same env file |

## Scheduled jobs

| Job | Schedule |
|---|---|
| nftables-ddns | 15 s after boot, then every 5 minutes |
| integrity-check | daily 03:00 |
| docker-update | daily 04:00 |
| unattended-upgrades | daily (apt timers) |
| debsums | weekly (cron) |
| fstrim | weekly (`fstrim.timer`, the distribution default) |

## Docker

`daemon.json`:

- nftables firewall backend, `userland-proxy: false`, `no-new-privileges`, `live-restore`
- journald logging, `nofile` 64000
- IPv6 with a ULA prefix

Start-order drop-ins in `/etc/systemd/system/docker.service.d/`:

| File | Purpose |
|---|---|
| `override.conf` | `After=` and `Requires=nftables.service`: no container starts before the firewall |
| `wait-for-rw.conf` | Waits until `/` is mounted read-write before starting dockerd |
| `wait-for-wg0.conf` | `After=` and `Wants=wg-quick@wg0.service`. AdGuard binds DNS only to the WireGuard address, so Docker must wait for `wg-quick` to finish. `Wants=` rather than `Requires=`, so a WireGuard failure costs only AdGuard's DNS |

I confirmed the last one across a reboot: `wg-quick` finished at 6.82 s and Docker started at 6.99 s. Before the drop-in, the order was down to timing.

**After restarting `wg-quick@wg0` by hand, restart AdGuard** (`sudo docker restart adguard`). The ordering rule covers boot only; a WireGuard restart removes the address from under AdGuard.

**Host DNS is independent of AdGuard.** `/etc/resolv.conf` points at a public resolver, so the host and Docker keep resolving names if AdGuard is down. AdGuard serves only WireGuard clients.

| Network | Subnet | Used by |
|---|---|---|
| `warpconduit` | 172.18.0.0/16 | Traefik and every service it fronts (Traefik is `.2`, FreshRSS `.50`, ntfy `.7`). Created by hand |
| `bridge` | 172.17.0.0/16 | Docker default, unused |

## WireGuard

This tunnel is the fallback half of a pair: every device also has a tunnel to the home router. The home side's per-device rules, and why switching between the two is manual, are in [narrow-tunnel](https://github.com/zacharyrichter/narrow-tunnel).

`/etc/wireguard/wg0.conf`, brought up by `wg-quick@wg0`:

- Server address `10.77.0.1/24`, UDP 51820.
- One peer per device, each with its own preshared key. Each `[Peer]` block starts with a comment naming the device.
- The directory holds only the server config and keys. Client configs, which contain private keys, are deleted as soon as the QR code has been scanned, and a replacement device gets a new peer.
- NAT and the peers' egress rules live in nftables, not in `wg0.conf`.

### Add a peer

```bash
sudo -i
umask 077
cd /etc/wireguard

NAME=<device-name>
IP=10.77.0.<next free number>        # sudo grep AllowedIPs wg0.conf lists the used ones
PRIV=$(wg genkey)
PUB=$(printf '%s' "$PRIV" | wg pubkey)
PSK=$(wg genpsk)
SERVER_PUB=$(wg show wg0 public-key)

cat > "$NAME.conf" <<EOF2
[Interface]
PrivateKey = $PRIV
Address = $IP/24
DNS = 10.77.0.1

[Peer]
PublicKey = $SERVER_PUB
PresharedKey = $PSK
Endpoint = vps.example.net:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF2

cat >> wg0.conf <<EOF2

[Peer]
#$NAME
PublicKey = $PUB
PresharedKey = $PSK
AllowedIPs = $IP/32
EOF2

wg syncconf wg0 <(wg-quick strip wg0)
wg show wg0 allowed-ips | grep -c "$IP"      # expect 1
qrencode -t ansiutf8 < "$NAME.conf"
```

Scan the QR code on the device, then `rm "$NAME.conf"` and leave the root shell. `wg syncconf` loads the peer without dropping the tunnel, so other devices stay connected and AdGuard needs no restart.

### Remove a peer

Delete the device's `[Peer]` block from `wg0.conf`, then:

```bash
sudo bash -c 'wg syncconf wg0 <(wg-quick strip wg0)'
sudo wg show wg0 allowed-ips | grep -c '10.77.0.<number>'      # expect 0
```

## Procedure

Changes are made by hand, one section at a time: read the current file, back it up with a dated name, edit, apply, verify.

- **sysctl:** edit the file in `/etc/sysctl.d/`, apply with `sudo sysctl -p <file>`, verify.
- **sshd:** edit `00-hardening.conf`, run `sudo sshd -t`, then `sudo systemctl reload ssh`. Test from a **new** session before closing the old one.
- **Firewall:** see [firewall-and-ddns-allowlist.md](firewall-and-ddns-allowlist.md). Never reload nftables on the live host.
- **Anything boot-related:** access is remote-only, so plan reboots with the provider's web console open.

## Verification

```bash
# Kernel settings (expect 2, 0, 1, 1)
sudo sysctl kernel.kptr_restrict kernel.sysrq net.ipv4.conf.all.log_martians net.ipv4.conf.eth0.rp_filter

# sshd effective configuration
sudo sshd -T | grep -Ei '^(port|authenticationmethods|allowusers|maxauthtries) '

# Audit rules loaded (expect "enabled 1" and the CIS rules)
sudo auditctl -s | head -1; sudo auditctl -l | wc -l

# Timers
systemctl list-timers --no-pager | grep -E 'integrity|docker-update|nftables-ddns|apt-daily'

# debsums clean apart from the expected file (expect no output and "exit 1")
sudo sh -c 'debsums -cs 2>&1 | grep -Evf /etc/debsums-ignore'; echo "exit $?"

# Boot order: wg-quick must finish before Docker starts
sudo journalctl -b --no-pager -o short-monotonic -u wg-quick@wg0 -u docker | grep -E 'Finished|Starting' | head -3

# Containers and listeners
sudo docker ps --format '{{.Names}} {{.Status}}'
sudo ss -tulpn
```

Expected listeners: sshd on the SSH port, Traefik on 443, WireGuard on 51820/udp, AdGuard on the WireGuard address (DNS) and `*:3000` (its UI, reachable only from Traefik because of the firewall).

## Recovery and rollback

- **Locked out of SSH:** if the allowlist is empty or stale, SSH still works from a WireGuard client or either static address. Failing that, use the provider's web console. A key-only login can't be locked out by faillock, which counts password failures.
- **A sysctl change breaks networking:** copy back the dated backup made before the edit and apply it, or reboot.
- **nftables was restarted by mistake:** `sudo systemctl restart docker` rebuilds Docker's tables; confirm the containers are up and that the allowlist refills within five minutes.
- **Integrity alert after a planned change:** expected. The next run takes the new state as its baseline.
