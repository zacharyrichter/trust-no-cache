# Logcheck — Setup Guide

## Overview

Logcheck scans system logs on a regular schedule and emails a report of any lines that match patterns of interest — security events, service failures, authentication attempts, and other anomalies. Known-benign log patterns can be suppressed using ignore rules so that reports only surface genuinely noteworthy entries.

**How it works:**

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

> **Prerequisite:** Complete the [Mailgun Email Setup Guide](./mailgun-email-setup.md) first.
> Logcheck sends reports via `/usr/local/bin/sendmail`, which must be in place before
> logcheck is configured.

---

## Prerequisites

- Debian/Ubuntu-based system with `sudo` access
- Mailgun email wrappers installed (see prerequisite above)

---

## Step 1: Install Logcheck

```bash
sudo apt update
sudo apt install logcheck logcheck-database -y
```

This creates the `logcheck` system user and installs the default rule sets under `/etc/logcheck/`.

---

## Step 2: Configure `/etc/logcheck/logcheck.conf`

```bash
sudo nano /etc/logcheck/logcheck.conf
```

Set the following values:

```bash
# Filtering level: "workstation", "server", or "paranoid"
# "server" is appropriate for a publicly-accessible system
REPORTLEVEL="server"

# Email address to send reports to
SENDMAILTO="your@email.com"

# Send as attachment: 0=inline, 1=attachment, 2=gzip attachment
MAILASATTACH=0

# Use short hostname in subject line
FQDN=0

# Use /tmp for temporary files
TMP="/tmp"
```

> **Note on `SENDMAILTO`:** Logcheck calls the system `sendmail` binary directly with this address as the recipient. Since `/usr/local/bin/sendmail` takes precedence over any system MTA in `PATH`, this routes through Mailgun automatically.

---

## Step 3: Configure `/etc/aliases`

Logcheck sends some mail to the `logcheck` local Unix account, which must be aliased through to root and then to a real address.

```bash
sudo nano /etc/aliases
```

Ensure these lines are present:

```
root: your@email.com
logcheck: root
```

Apply the aliases:

```bash
sudo newaliases 2>/dev/null || true
```

---

## Step 4: Configure Log Sources

Logcheck reads which logs to scan from files in `/etc/logcheck/logcheck.logfiles.d/`. The default installation includes two sources:

- `journal.logfiles` — scans the systemd journal
- `syslog.logfiles` — scans `/var/log/syslog` (if present)

These cover the majority of system activity. To add additional log files, create a new file in the directory:

```bash
sudo nano /etc/logcheck/logcheck.logfiles.d/local.logfiles
```

```
/var/log/auth.log
/var/log/kern.log
```

Each line should be an absolute path to a log file, or the word `journal` to include the systemd journal.

---

## Step 5: Add a Custom Header

Logcheck prepends a header to every report email. Customise it so recipients know where the mail originated:

```bash
sudo nano /etc/logcheck/header.txt
```

```
This email is sent by logcheck. If you no longer wish to receive
such mail, you can either uninstall the logcheck package or modify
its configuration file (/etc/logcheck/logcheck.conf).
```

---

## Step 6: Add Custom Ignore Rules

Out of the box, logcheck ships with extensive ignore rules for common Debian services under `/etc/logcheck/ignore.d.server/`. You will likely need to add your own rules to suppress noise from local services and Docker containers.

Create a local ignore file:

```bash
sudo nano /etc/logcheck/ignore.d.server/local-docker-noise
```

The following rules suppress common Docker container log noise. Each line is an extended regular expression matched against a full syslog-format log line. Replace `your-server` with your actual hostname in the rules below.

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
# Replace "your-server" with your actual hostname
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

> **Tip on writing ignore rules:** Each rule is an extended regex anchored to a full log line. The syslog prefix format is `^\w{3} [ :[:digit:]]{11} [._[:alnum:]-]+ processname\[pid\]:`. Test new rules against your logs with:
> ```bash
> sudo grep "the noisy line" /var/log/syslog | logcheck-test my-rule-pattern
> ```

---

## Step 7: Enable the Timer and Verify the Cron Schedule

Logcheck runs via `/etc/cron.d/logcheck`, installed automatically by the package. On systemd systems the cron jobs skip themselves because a `logcheck.timer` unit takes precedence. This timer is package-managed and lives in `/lib/systemd/system/` rather than `/etc/systemd/system/`.

Enable and start the timer:

```bash
sudo systemctl enable --now logcheck.timer
```

Verify it is active and check when it will next run:

```bash
systemctl list-timers logcheck.timer
```

---

## Step 8: Run a Manual Check

Test the full pipeline — log scanning, filtering, and email delivery — before waiting for the scheduled run:

```bash
sudo logcheck -o -t
```

- `-o` — one-shot: send the report even if it is empty
- `-t` — test mode: print what would be sent without actually mailing it

To do a full live test including email delivery:

```bash
sudo logcheck -o
```

Check your inbox. A successful first run typically generates a report with a handful of recent log lines that did not match any ignore rules.

---

## File Reference

| Path | Purpose |
|---|---|
| `/etc/logcheck/logcheck.conf` | Main configuration — report level, recipient, mail options |
| `/etc/logcheck/logcheck.logfiles` | Log source list (superseded by `logcheck.logfiles.d/`) |
| `/etc/logcheck/logcheck.logfiles.d/` | Directory of log source files |
| `/etc/logcheck/ignore.d.server/` | Ignore rules for `server` report level |
| `/etc/logcheck/ignore.d.server/local-docker-noise` | Custom ignore rules for Docker container noise |
| `/etc/logcheck/header.txt` | Prepended to every report email |
| `/etc/logcheck/violations.d/` | Patterns that force a report regardless of level |
| `/etc/cron.d/logcheck` | Cron schedule (hourly + reboot) |
| `/usr/local/bin/sendmail` | Mailgun sendmail wrapper used for delivery |
| `/etc/aliases` | Routes `logcheck` and `root` mail to a real address |

---

## Troubleshooting

| Symptom | Likely Cause | Action |
|---|---|---|
| No email received after manual run | `sendmail` wrapper missing or misconfigured | Test: `echo test \| sudo /usr/local/bin/sendmail your@email.com` |
| Reports contain too much noise | Missing ignore rules | Add patterns to `ignore.d.server/local-docker-noise` and re-run |
| Reports are empty every hour | All log lines being ignored | Temporarily run with `-o` flag; check that log sources are correct |
| `Permission denied` reading ignore rules | Running as wrong user | Logcheck must run as the `logcheck` user via cron/systemd, not as root |
| `logcheck.timer` not found or inactive | systemd timer not installed or not enabled | Run `sudo systemctl enable --now logcheck.timer`; if not found, reinstall with `sudo apt install --reinstall logcheck -y` |
| Reboot report not received | Network not ready when logcheck ran at boot | Expected if mail relay is unreachable at boot; hourly run will catch up |
