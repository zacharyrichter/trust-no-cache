# AIDE, Logcheck & Logdy — Monitoring Setup Guide

Referenced from [`server-hardening.md`](server-hardening.md) Sections 12 and 13. Covers
file integrity monitoring (AIDE), log anomaly scanning (logcheck), and an optional web-
based log viewer (Logdy) that replaces email delivery for both.

## Part 1: AIDE

Requires [`mailgun-relay.md`](mailgun-relay.md) completed first — AIDE sends
reports via `/usr/local/bin/mail`.

> **Optional overlay:** Part 3 of this guide (Logdy) replaces email delivery of routine
> AIDE reports with a browser-accessible log viewer, keeping email only for changes/errors.

## Overview

```
┌──────────────────────┐       ┌────────────────────────┐
│  Initial database    │       │  Daily cron job        │
│  aide --init         │──────▶│  dailyaidecheck        │
│  /var/lib/aide/      │       │  (compares live FS     │
│  aide.db             │       │   against aide.db)     │
└──────────────────────┘       └────────────┬───────────┘
                                            │ changes found
                                            ▼
                                 /usr/local/bin/mail
                                            │
                                            ▼
                                 your@email.com
```

## Step 1: Install AIDE

```bash
sudo apt update
sudo apt install aide aide-common -y
```

## Step 2: Configure `/etc/aide/aide.conf`

Per-package rules are managed automatically under `/etc/aide/aide.conf.d/`.

```bash
sudo nano /etc/aide/aide.conf
```

```
database_in=file:/var/lib/aide/aide.db
database_out=file:/var/lib/aide/aide.db.new
database_new=file:/var/lib/aide/aide.db.new
gzip_dbout=yes

report_ignore_e2fsattrs=VNIE
```

Below the `@@x_include` directive, add exclusions for frequently-changing paths (adjust
to your environment):

```
@@x_include /etc/aide/aide.conf.d ^[a-zA-Z0-9_-]+$

# --- DOCKER INTERNALS & RUNTIME ---
!/var/lib/docker/rootfs/.*
!/var/lib/docker/volumes/.*
!/var/lib/docker/image/.*
!/var/lib/docker/containers/.*
!/var/lib/docker/network/.*
!/var/lib/docker/tmp/.*
!/var/lib/containerd/.*
!/root/.docker/.*

# --- SYSTEM TRANSIENTS ---
!/run/docker/.*
!/run/containerd/.*
!/run/systemd/.*
!/run/udev/.*
!/run/cf_response.json
!/run/unattended-upgrades.lock
!/run/nftables-ddns.log
!/run/user
!/run/lock
!/run/xrdp

# --- TEMPORARY STORAGE ---
!/tmp/.*
!/var/tmp/.*

# --- PACKAGE MANAGEMENT & UPDATES ---
!/var/cache/apt
!/var/cache/apt/.*
!/var/lib/apt/periodic/.*
!/var/log/unattended-upgrades/.*
!/var/log/docker-update.log
!/var/log/logcheck/.*

# --- APPLICATION SPECIFIC LOGS & DATA ---
!/opt/appdata/traefik/config/logs/.*
!/opt/appdata/adguard/work/data/filters/.*
!/opt/appdata/adguard/work/.*

# --- SYSTEM MAINTENANCE & AIDE INTERNAL ---
!/var/lib/aide/aide\.db\.new.*
!/var/lib/systemd/timers/stamp-dailyaidecheck\.timer
!/var/lib/systemd/timers/stamp-docker-update\.timer
!/var/lib/systemd/timers/stamp-logcheck\.timer
!/var/lib/systemd/timers/stamp-minecraft-backup.timer
!/var/lib/aide/aide.db
!/var/log/wtmp.db

# --- MULLVAD BROWSER & XRDP ---
!/home/youruser/.mullvad-browser
!/home/youruser/.bash_history
!/home/youruser/.Xauthority
!/home/youruser/.xorgxrdp.*
!/home/youruser/.xsession-errors
!/home/youruser/.cache/openbox
!/home/youruser/.local/share/xrdp
!/var/log/xrdp.*
!/var/log/xrdp-sesman.*
!/etc/xrdp
!/home/youruser/thinclient_drives

# --- DOCKER CONTAINERS ---
!/opt/appdata/yarr/.*
!/opt/appdata/adguard/config/.*
!/root/.local/share/nano/search_history
```

> Add further exclusions with a `!` prefix, then re-initialise (Step 4).

## Step 3: Install the `mail` Wrapper

Covered in [`mailgun-relay.md`](mailgun-relay.md), Step 5. Verify:

```bash
ls -la /usr/local/bin/mail
```

## Step 4: Initialise the Database

```bash
sudo aideinit
sudo cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

> Initialise **after** all software is installed and configured. Re-initialise after any
> intentional system change to avoid false positives.

## Step 5: Enable the Daily Timer

```bash
ls -la /etc/cron.daily/dailyaidecheck
sudo systemctl enable --now dailyaidecheck.timer
systemctl list-timers dailyaidecheck.timer
```

The cron script defers to `dailyaidecheck.timer` (package-managed, lives in
`/lib/systemd/system/`) when systemd is running.

**`capsh`:** the daily check drops privileges to `_aide` via `capsh`. Falls back to full
capabilities if missing — install for a clean setup:

```bash
sudo apt install libcap2-bin -y
```

## Step 6: Configure the apt Post-Invoke Hook

Without this, every apt operation causes false positives on the next check since the
database no longer matches updated files.

```bash
sudo nano /etc/apt/apt.conf.d/99-post-upgrade-hook
```

```
DPkg::Post-Invoke {
    "aide --update --config /etc/aide/aide.conf && cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db || true";
};
```

`|| true` ensures apt never fails due to AIDE's exit code.

> Runs synchronously after every dpkg operation — can take several minutes on large
> filesystems.

## Step 7: Run a Manual Check

```bash
sudo aide --check
```

Exits silently if no changes. To test email delivery, touch a monitored file, run the
check, then restore it and update the database:

```bash
sudo aide --update
sudo cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

## Step 8: Add Custom Exclusions (As Needed)

```bash
sudo nano /etc/aide/aide.conf
# Add: !/var/log/some-noisy.log

sudo aide --update
sudo cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

## File Reference

| Path | Purpose |
|---|---|
| `/etc/aide/aide.conf` | Main configuration — checksum groups, exclusions |
| `/etc/aide/aide.conf.d/` | Per-package rules, managed by Debian packages |
| `/var/lib/aide/aide.db` | Active baseline database |
| `/var/lib/aide/aide.db.new` | Newly generated database (copy to `.db` to activate) |
| `/usr/share/aide/bin/dailyaidecheck` | Daily check script |
| `/etc/cron.daily/dailyaidecheck` | Cron entry (defers to systemd timer) |
| `/etc/apt/apt.conf.d/99-post-upgrade-hook` | Auto-updates AIDE database after apt operations |
| `/usr/local/bin/mail` | Mail wrapper used by AIDE |

## Troubleshooting

| Symptom | Likely Cause | Action |
|---|---|---|
| No daily email | Timer not active or mail wrapper missing | `sudo systemctl enable --now dailyaidecheck.timer`; verify `/usr/local/bin/mail` exists |
| Timer not found | Package not fully installed | `sudo apt install --reinstall aide aide-common -y` |
| False positives after apt upgrade | apt hook not installed | Create the hook per Step 6 |
| False positives after manual changes | Database not updated | `sudo aide --update && sudo cp .../aide.db.new .../aide.db` |
| `aide.db` not found | Database not initialised | `sudo aideinit && sudo cp ...` |
| Report shows changes after package update | apt hook not running | Verify hook file exists and is readable |
| Check runs, no email | Mailgun wrapper misconfigured | `echo test \| sudo /usr/local/bin/mail -s "AIDE test"` |

---


---

## Part 2: Logcheck

Requires [`mailgun-relay.md`](mailgun-relay.md) completed first.

> **Optional overlay:** Part 3 of this guide (Logdy) redirects logcheck reports from
> email to a flat file, viewable in a browser, and moves the timer to 07:00 to avoid
> overlapping AIDE's nightly run.

## Overview

```
┌──────────────────────┐      ┌───────────────────────────┐
│  System logs         │      │  Logcheck (hourly cron)   │
│  /var/log/syslog     │─────▶│  Scans new log lines      │
│  systemd journal     │      │  since last run           │
└──────────────────────┘      └────────────┬──────────────┘
                                           │
                              ┌────────────▼──────────────┐
                              │  Filter against rules in  │
                              │  ignore.d.server/         │
                              └────────────┬──────────────┘
                                           │ unmatched lines
                                           ▼
                                /usr/local/bin/sendmail
                                           │
                                           ▼
                                your@email.com
```

## Step 1: Install Logcheck

```bash
sudo apt update
sudo apt install logcheck logcheck-database -y
```

Creates the `logcheck` system user and default rule sets under `/etc/logcheck/`.

## Step 2: Configure `/etc/logcheck/logcheck.conf`

```bash
sudo nano /etc/logcheck/logcheck.conf
```

```bash
REPORTLEVEL="server"
SENDMAILTO="your@email.com"
MAILASATTACH=0
FQDN=0
TMP="/tmp"
```

> `SENDMAILTO` is passed to the system `sendmail` binary. Since
> `/usr/local/bin/sendmail` precedes any system MTA in PATH, this routes through Mailgun.

## Step 3: Configure `/etc/aliases`

```bash
sudo nano /etc/aliases
```

```
root: your@email.com
logcheck: root
```

```bash
sudo newaliases 2>/dev/null || true
```

## Step 4: Configure Log Sources

Default sources in `/etc/logcheck/logcheck.logfiles.d/` (`journal.logfiles`,
`syslog.logfiles`) cover most activity. To add more:

```bash
sudo nano /etc/logcheck/logcheck.logfiles.d/local.logfiles
```

```
/var/log/auth.log
/var/log/kern.log
```

## Step 5: Add a Custom Header

```bash
sudo nano /etc/logcheck/header.txt
```

```
This email is sent by logcheck. If you no longer wish to receive
such mail, you can either uninstall the logcheck package or modify
its configuration file (/etc/logcheck/logcheck.conf).
```

## Step 6: Add Custom Ignore Rules

```bash
sudo nano /etc/logcheck/ignore.d.server/local-docker-noise
```

Each line is an extended regex matched against a full syslog-format line. Replace
`your-server` with your actual hostname throughout.

```
# local-docker-noise
# Covers: Docker/containerd lifecycle, AdGuard Home, unattended-upgrades,
#         PAM sessions, kernel veth/bridge churn, application noise

# -----------------------------------------------------------------------
# Application noise (Invidious / Yattee / Redlib)
# -----------------------------------------------------------------------
^\w{3} [ :[:digit:]]{11} [._[:alnum:]-]+ [a-zA-Z0-9]+\[[[:digit:]]+\]: - feed_fetcher - .*$
^\w{3} [ :[:digit:]]{11} [._[:alnum:]-]+ [a-zA-Z0-9]+\[[[:digit:]]+\]: - invidious_proxy - .*$
^\w{3} [ :[:digit:]]{11} [._[:alnum:]-]+ [a-zA-Z0-9]+\[[[:digit:]]+\]: - httpx - .*$
^\w{3} [ :[:digit:]]{11} [._[:alnum:]-]+ [a-zA-Z0-9]+\[[[:digit:]]+\]: ThrottlingCache:.*$
^\w{3} [ :[:digit:]]{11} [._[:alnum:]-]+ [a-zA-Z0-9]+\[[[:digit:]]+\]: Cleanup:.*$
^\w{3} [ :[:digit:]]{11} [._[:alnum:]-]+ [a-zA-Z0-9]+\[[[:digit:]]+\]: PubSub:.*$
^\w{3} [ :[:digit:]]{11} [._[:alnum:]-]+ [a-zA-Z0-9]+\[[[:digit:]]+\]:$

# -----------------------------------------------------------------------
# systemd generic
# -----------------------------------------------------------------------
^\w{3} [ :[:digit:]]{11} [._[:alnum:]-]+ systemd\[[[:digit:]]+\]: Configuration file .* is marked world-inaccessible.*$
^\w{3} [ :[:digit:]]{11} [._[:alnum:]-]+ systemd\[[[:digit:]]+\]: Reloading\.$
^\w{3} [ :[:digit:]]{11} [._[:alnum:]-]+ systemd\[[[:digit:]]+\]: Reloading\.\.\.$
^\w{3} [ :[:digit:]]{11} [._[:alnum:]-]+ systemd\[[[:digit:]]+\]: Reloading finished in.*$
^\w{3} [ :[:digit:]]{11} [._[:alnum:]-]+ systemd\[[[:digit:]]+\]: Reload requested from client.*$
^\w{3} [ :[:digit:]]{11} [._[:alnum:]-]+ systemd-sysv-generator\[[[:digit:]]+\]: .*exim4.*$

# -----------------------------------------------------------------------
# Kernel — Docker veth/bridge interface state churn
# -----------------------------------------------------------------------
^\w{3} [ :[:digit:]]{11} your-server kernel: br-[0-9a-f]+: port [0-9]+\([a-z0-9]+\) entered (blocking|disabled|forwarding) state$
^\w{3} [ :[:digit:]]{11} your-server kernel: [a-z0-9]+( \(unregistering\))?: (left|entered) (allmulticast|promiscuous) mode$
^\w{3} [ :[:digit:]]{11} your-server kernel: [a-z0-9]+: renamed from [a-z0-9]+$
^\w{3} [ :[:digit:]]{11} your-server (udev-worker)\[[0-9]+\]: Network interface NamePolicy= disabled on kernel command line\.$

# -----------------------------------------------------------------------
# containerd — shim lifecycle
# -----------------------------------------------------------------------
^\w{3} [ :[:digit:]]{11} your-server containerd\[[0-9]+\]: time="[^"]+" level=info msg="(shim disconnected|cleaning up after shim disconnected|cleaning up dead shim|connecting to shim [0-9a-f]+)" (id=[0-9a-f]+ )?namespace=moby.*$

# -----------------------------------------------------------------------
# dockerd — routine lifecycle events
# -----------------------------------------------------------------------
^\w{3} [ :[:digit:]]{11} your-server dockerd\[[0-9]+\]: time="[^"]+" level=info msg="received task-delete event from containerd" container=[0-9a-f]+ module=libcontainerd namespace=moby.*$
^\w{3} [ :[:digit:]]{11} your-server dockerd\[[0-9]+\]: time="[^"]+" level=info msg="stopping restart-manager" container=[0-9a-f]+$
^\w{3} [ :[:digit:]]{11} your-server dockerd\[[0-9]+\]: time="[^"]+" level=info msg="sbJoin: gwep[46] '[0-9a-f]*'->'[0-9a-f]*', gwep[46] '[0-9a-f]*'->'[0-9a-f]*'" eid=[0-9a-f]+ ep=\S+ net=\S+ nid=[0-9a-f]+ spanID=[0-9a-f]+ traceID=[0-9a-f]+$
# Known image pulls — one rule per image so unexpected pulls remain visible.
^\w{3} [ :[:digit:]]{11} your-server dockerd\[[0-9]+\]: time="[^"]+" level=info msg="image pulled" digest="sha256:[0-9a-f]+" remote="docker\.io/adguard/adguardhome:latest" spanID=[0-9a-f]+ traceID=[0-9a-f]+$
^\w{3} [ :[:digit:]]{11} your-server dockerd\[[0-9]+\]: time="[^"]+" level=info msg="image pulled" digest="sha256:[0-9a-f]+" remote="docker\.io/library/traefik:latest" spanID=[0-9a-f]+ traceID=[0-9a-f]+$
^\w{3} [ :[:digit:]]{11} your-server dockerd\[[0-9]+\]: time="[^"]+" level=info msg="image pulled" digest="sha256:[0-9a-f]+" remote="docker\.io/valkey/valkey:8-alpine" spanID=[0-9a-f]+ traceID=[0-9a-f]+$
^\w{3} [ :[:digit:]]{11} your-server dockerd\[[0-9]+\]: time="[^"]+" level=info msg="image pulled" digest="sha256:[0-9a-f]+" remote="docker\.io/searxng/searxng:latest" spanID=[0-9a-f]+ traceID=[0-9a-f]+$
^\w{3} [ :[:digit:]]{11} your-server dockerd\[[0-9]+\]: time="[^"]+" level=info msg="image pulled" digest="sha256:[0-9a-f]+" remote="docker\.io/brainicism/bgutil-ytdlp-pot-provider:latest" spanID=[0-9a-f]+ traceID=[0-9a-f]+$
^\w{3} [ :[:digit:]]{11} your-server dockerd\[[0-9]+\]: time="[^"]+" level=info msg="image pulled" digest="sha256:[0-9a-f]+" remote="quay\.io/redlib/redlib:latest" spanID=[0-9a-f]+ traceID=[0-9a-f]+$
^\w{3} [ :[:digit:]]{11} your-server dockerd\[[0-9]+\]: time="[^"]+" level=warning msg="forcibly turning on oci-mediatype mode for attestations" span="exporting to image" spanID=[0-9a-f]+ traceID=[0-9a-f]+$
^\w{3} [ :[:digit:]]{11} your-server systemd\[1\]: docker-[0-9a-f]+\.scope: Consumed [0-9.]+(ms|s|min [0-9.]+s) CPU time,.*$

# -----------------------------------------------------------------------
# AdGuard Home — filter updates and startup verbosity
# -----------------------------------------------------------------------
^\w{3} [ :[:digit:]]{11} your-server [0-9a-f]+\[[0-9]+\]: [0-9/: .]+ \[info\] filtering: (saving contents id=[0-9]+ path=/opt/adguardhome/work/data/filters/[0-9]+\.txt|filter updated id=[0-9]+ bytes_written=[0-9]+ rules_count=[0-9]+|updated filter id=[0-9]+ rules_count=[0-9]+ prev_rules_count=[0-9]+)$
^\w{3} [ :[:digit:]]{11} your-server [0-9a-f]+\[[0-9]+\]: [0-9/: .]+ \[info\] (go to https?://[^ ]+|starting adguard home version=|webapi: (initializing|AdGuard Home is available|stopping http server|stopped http server)|dnsproxy: (upstream mode is set|cache enabled|max goroutines|cache ttl override|server will refuse|starting dns proxy server|creating (udp|tcp) server socket|listening to (udp|tcp)|entering (udp )?listener loop|stopped dns proxy server|stopping server)|addrproc: processing addresses|tls_manager: using default ciphers|dhcpd: warning: creating dhcpv4 server|signalhdlr: received signal|stopping AdGuard Home|stopped)
^\w{3} [ :[:digit:]]{11} your-server [0-9a-f]+\[[0-9]+\]: Started POT server \(v[0-9.]+\) on on address \[::\]:[0-9]+$

# -----------------------------------------------------------------------
# unattended-upgrades
# -----------------------------------------------------------------------
^\w{3} [ :[:digit:]]{11} your-server unattended-upgrade\[[0-9]+\]: (Enabled logging to syslog via daemon facility|Checking if system is running on battery.*|Starting unattended upgrades script|Allowed origins are:.*|Initial (blacklist|whitelist).*|No packages found that can be upgraded.*)$

# -----------------------------------------------------------------------
# PAM / user sessions — intentionally NOT suppressed
# logcheck should surface all session open/close events so unexpected
# logins remain visible. Do not add rules here.
# -----------------------------------------------------------------------
```

> Test new rules against real log lines:
> ```bash
> sudo grep "the noisy line" /var/log/syslog | logcheck-test my-rule-pattern
> ```

## Step 7: Enable the Timer

`logcheck.timer` (package-managed, `/lib/systemd/system/`) takes precedence over the
`/etc/cron.d/logcheck` entry on systemd systems.

```bash
sudo systemctl enable --now logcheck.timer
systemctl list-timers logcheck.timer
```

## Step 8: Run a Manual Check

```bash
sudo logcheck -o -t   # -o: one-shot even if empty, -t: test mode, no send
sudo logcheck -o      # full live test including delivery
```

## File Reference

| Path | Purpose |
|---|---|
| `/etc/logcheck/logcheck.conf` | Main configuration |
| `/etc/logcheck/logcheck.logfiles.d/` | Log source files |
| `/etc/logcheck/ignore.d.server/` | Ignore rules for `server` report level |
| `/etc/logcheck/ignore.d.server/local-docker-noise` | Custom ignore rules |
| `/etc/logcheck/header.txt` | Prepended to every report email |
| `/etc/logcheck/violations.d/` | Patterns that force a report regardless of level |
| `/etc/cron.d/logcheck` | Cron schedule (hourly + reboot) |

## Troubleshooting

| Symptom | Likely Cause | Action |
|---|---|---|
| No email after manual run | `sendmail` wrapper missing/misconfigured | `echo test \| sudo /usr/local/bin/sendmail your@email.com` |
| Reports too noisy | Missing ignore rules | Add patterns to `local-docker-noise`, re-run |
| Reports empty every hour | All lines being ignored | Run with `-o`, check log sources |
| `Permission denied` reading ignore rules | Wrong user | Must run as `logcheck` user via cron/systemd, not root |
| Timer not found/inactive | Not installed/enabled | `sudo systemctl enable --now logcheck.timer`; reinstall if needed |
| Reboot report missing | Mail relay unreachable at boot | Expected; hourly run catches up |

---


---

## Part 3: Logdy Log Viewer

Optional overlay on Parts 1 and 2 above — replaces email-based delivery of AIDE and
logcheck reports with a browser-accessible web UI. AIDE keeps email alerts for
changes/errors only (`QUIETREPORTS=yes`); logcheck is redirected from Mailgun to a flat
file entirely.

## Overview

| Component | Role |
|---|---|
| AIDE | Filesystem integrity checker — nightly via systemd timer |
| logcheck | Log anomaly scanner — daily at 07:00 via systemd timer |
| Logdy | Single-binary log viewer, ~14MB RAM, web UI |
| Traefik | Reverse proxy — TLS and basic auth in front of Logdy |

logcheck's timer is overridden to 07:00 to avoid overlap with AIDE's nightly window
(02:00–04:00), when AIDE can peak at 500MB–1GB RAM. Logdy tails the live log file plus
one rotated file per source, served on `0.0.0.0:8080` — bound to all interfaces since
Traefik reaches it via the Docker bridge gateway, not loopback.

## Prerequisites

```bash
ls -lh /var/log/aide/aide.log
logcheck --help 2>&1 | grep "\-o"
sudo mkdir -p /etc/systemd/system/logcheck.service.d/
sudo mkdir -p /etc/systemd/system/logcheck.timer.d/
```

## Step 1 — Redirect logcheck output to a file

Uses logcheck's native `-o` flag combined with systemd's `StandardOutput=append:`. No
mail wrapper involved.

Create `/etc/systemd/system/logcheck.service.d/override.conf`:

```ini
[Service]
ExecStart=
ExecStart=/usr/sbin/logcheck -o
StandardOutput=append:/var/log/logcheck/logcheck.log
```

> The blank `ExecStart=` clears the original command before redefining it — required
> systemd drop-in syntax.

Create `/etc/systemd/system/logcheck.timer.d/override.conf`:

```ini
[Timer]
OnCalendar=
OnCalendar=*-*-* 07:00:00
```

```bash
sudo mkdir -p /var/log/logcheck
sudo chown logcheck:adm /var/log/logcheck
sudo chmod 750 /var/log/logcheck

sudo systemctl daemon-reload
sudo systemctl cat logcheck.service
sudo systemctl cat logcheck.timer
systemctl list-timers logcheck.timer

sudo systemctl start logcheck.service
sudo cat /var/log/logcheck/logcheck.log
```

An empty file means logcheck found nothing to report — normal on a quiet system. Confirm
the service ran cleanly with `sudo systemctl status logcheck.service`.

## Step 2 — Install Logdy

```bash
curl -O -L https://github.com/logdyhq/logdy-core/releases/latest/download/logdy_linux_amd64
chmod +x logdy_linux_amd64
sudo mv logdy_linux_amd64 /usr/local/bin/logdy
logdy --version
```

## Step 3 — Logdy systemd service

Create `/etc/systemd/system/logdy.service`:

```ini
[Unit]
Description=Logdy log viewer
After=network.target

[Service]
ExecStart=/usr/local/bin/logdy follow --full-read --ui-ip 0.0.0.0 --port 8080 --no-analytics /var/log/aide/aide.log /var/log/logcheck/logcheck.log /var/log/logcheck/logcheck.log.1
Restart=on-failure
User=root
Group=adm

[Install]
WantedBy=multi-user.target
```

| Flag | Purpose |
|---|---|
| `follow` | Tail files, watch for new content |
| `--full-read` | Read from the start of each file on startup — no history lost on restart |
| `--ui-ip 0.0.0.0` | Bind all interfaces so Traefik's Docker bridge can reach the host |
| `--port 8080` | Port Traefik proxies to via `http://172.18.0.1:8080` |
| `--no-analytics` | Disable anonymous usage reporting |

`logcheck.log.1` is the previous week's uncompressed rotated file (Step 4) — gives Logdy
access to the most recent rotation without decompressing. Logdy logs a harmless warning
about this file until the first rotation occurs.

`aide.log` is owned `_aide:adm` (640), `logcheck.log` is owned `logcheck:adm` (640) — both
readable by group `adm`, hence `Group=adm`.

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now logdy.service
sudo systemctl status logdy.service
```

Expected: `Active: active (running)`, ~14M memory, `WebUI started, visit http://0.0.0.0:8080`.

## Step 4 — logrotate

Logdy can only read uncompressed files. `delaycompress` keeps the most recently rotated
file uncompressed for one cycle.

Create `/etc/logrotate.d/logcheck-file`:

```
/var/log/logcheck/logcheck.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 640 logcheck adm
}
```

`logcheck.log.1` stays uncompressed and readable by Logdy; `.2` and older compress as
normal.

## Step 5 — nftables rule

Traefik reaches host services via the `br-<network_id>` bridge — same pattern as AdGuard
on port 3000:

```bash
sudo nft add rule inet filter input iifname "br-<network_id>" tcp dport 8080 accept
sudo nft list chain inet filter input
sudo nft list ruleset | sudo tee /etc/nftables.conf
```

Port 8080 is only reachable via the Traefik bridge, not exposed to the internet directly.

## Step 6 — Traefik configuration

Logdy is exposed via Traefik's dynamic config at `/opt/appdata/traefik/config/dynamic.yml`.

Router:

```yaml
logdy:
  entryPoints:
    - https
  rule: "Host(`logdy.yourdomain.org`)"
  middlewares:
    - secured-chain@file
    - logdy-auth@file
  service: logdy
```

Service:

```yaml
logdy:
  loadBalancer:
    servers:
      - url: http://172.18.0.1:8080
    passHostHeader: true
```

Auth middleware:

```yaml
logdy-auth:
  basicAuth:
    users:
      - "youruser:$2y$..."   # generated with: htpasswd -nB -C 12 youruser
```

Generate/regenerate the hash:

```bash
sudo apt install apache2-utils -y
htpasswd -nB -C 12 youruser
```

Paste the full output line as the user entry. Use `$2y$` hashes from `htpasswd` only —
some Traefik versions are sensitive to `$2b$` hashes from other tools.

## Verification

```bash
sudo systemctl status logdy.service
sudo journalctl -u logdy.service -n 20 --no-pager

sudo systemctl start logcheck.service
tail /var/log/logcheck/logcheck.log

systemctl list-timers logcheck.timer
sudo journalctl -u dailyaidecheck.service -n 10 --no-pager
systemctl list-timers | grep -E "aide|logcheck"

sudo nft list chain inet filter input | grep 8080
curl -I https://logdy.yourdomain.org
```

## Logdy UI Quick Reference

Access at `https://logdy.yourdomain.org`, authenticated via Traefik basicAuth.

| Feature | How |
|---|---|
| Full-text search | Search bar — e.g. `raw includes "changed"` |
| Time range filter | Time picker in top bar — second-level precision |
| Sort order | Toggle newest/oldest, persisted across sessions |
| Faceted filters | Auto-generated in left panel — click to filter instantly |

Useful queries:

```
raw includes "Changed entries"       # AIDE detected filesystem changes
raw includes "AIDE error"            # Any AIDE error
raw includes "No changes detected"   # Clean AIDE run confirmation
raw includes "WARNING"               # logcheck flagged something
```

## Log File Reference

| File | Owner | Written by | Frequency |
|---|---|---|---|
| `/var/log/aide/aide.log` | `_aide:adm` | `dailyaidecheck` service | Nightly (~02:00) |
| `/var/log/aide/aide.log.0` | `_aide:adm` | Previous day (rotated by savelog) | — |
| `/var/log/aide/aide.log.N.gz` | `_aide:adm` | Older history — not readable by Logdy | — |
| `/var/log/logcheck/logcheck.log` | `logcheck:adm` | `logcheck` service | Daily at 07:00 |
| `/var/log/logcheck/logcheck.log.1` | `logcheck:adm` | Previous week — uncompressed, readable | — |
| `/var/log/logcheck/logcheck.log.N.gz` | `logcheck:adm` | Older history — not readable by Logdy | — |

Compressed `.gz` history is not readable by Logdy — use `zcat` for older entries.

## Notes

AIDE regularly peaks 500MB–1GB RAM during its nightly run; logcheck's 07:00 schedule
avoids overlapping the 02:00–04:00 AIDE window.

Logdy holds logs in a memory buffer (default 100,000 lines). `--full-read` repopulates
the buffer from disk on every restart, so restarts don't lose history that exists on disk.
