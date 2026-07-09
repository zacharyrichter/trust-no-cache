# Mailgun System Email — Setup Guide

Referenced from [`server-hardening.md`](server-hardening.md) Section 11.

## Overview

Three lightweight wrapper scripts intercept mail from system tools and relay it through
the Mailgun HTTP API, rather than running a local MTA for outbound delivery.

```
┌─────────────────┐     ┌──────────────────────────┐     ┌──────────────────┐
│  System tool    │────▶│  Wrapper script           │────▶│  Mailgun API     │
│  (AIDE,         │     │  /usr/local/bin/sendmail  │     │  yourdomain.org  │
│   logcheck,     │     │  /usr/local/bin/mail      │     └────────┬─────────┘
│   cron, etc.)   │     │  /usr/local/bin/mailgun-  │              │
└─────────────────┘     │  send                     │              ▼
                        └──────────────────────────┘     your@email.com
```

| Script | Purpose |
|---|---|
| `/usr/local/bin/sendmail` | Drop-in for system `sendmail`. Intercepts cron/logcheck mail. Parses `Subject:` from stdin. |
| `/usr/local/bin/mail` | Replacement for `mail`. Used by AIDE. Supports `-s "subject"`. |
| `/usr/local/bin/mailgun-send` | General-purpose sender for custom scripts. Optional recipient as `$1`. |

## Prerequisites

- Mailgun account with a verified sending domain (MX, SPF, DKIM configured)

## Step 1: Install Dependencies

```bash
sudo apt update
sudo apt install curl -y
```

## Step 2: Create a Mailgun API Key

Mailgun dashboard → **Settings** → **API Keys** → **Add new key** → copy immediately.

> Use a separate key per machine — a compromised key can be revoked independently.

## Step 3: Verify Your Sending Domain

Mailgun dashboard → **Sending** → **Domains** → confirm **Verified** status. The sending
address (e.g. `noreply@yourdomain.org`) doesn't need a real mailbox, just a valid address
in a verified domain.

## Step 4: Install the `sendmail` Wrapper

```bash
sudo nano /usr/local/bin/sendmail
```

```bash
#!/bin/bash
MAILGUN_API_KEY="<YOUR_API_KEY>"
MAILGUN_DOMAIN="yourdomain.org"
FROM="noreply@yourdomain.org"
TO="your@email.com"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|-F|-r) shift 2 ;;
        -*) shift ;;
        *) TO="$1"; break ;;
    esac
done
INPUT=$(cat)

SUBJECT=$(echo "$INPUT" 2>/dev/null | grep -m1 "^Subject:" | sed 's/Subject: //')
if [ -n "$SUBJECT" ]; then
    BODY=$(echo "$INPUT" | awk 'found{print} /^$/{found=1}')
else
    SUBJECT="System notification from $(hostname)"
    BODY="$INPUT"
fi

if [ -z "$BODY" ]; then
    BODY="$INPUT"
fi

TMPFILE=$(mktemp)
echo "$BODY" > "$TMPFILE"

HTTP_CODE=$(curl -s -o /tmp/mailgun_response.txt -w "%{http_code}" \
  --user "api:${MAILGUN_API_KEY}" \
  "https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages" \
  -F from="${FROM}" \
  -F to="${TO}" \
  -F subject="${SUBJECT:-No Subject}" \
  -F "text=<${TMPFILE}")

CURL_EXIT=$?
rm -f "$TMPFILE"

if [ $CURL_EXIT -ne 0 ]; then
    logger -t sendmail-wrapper "curl failed with exit code $CURL_EXIT"
    exit 1
fi

if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    RESPONSE=$(cat /tmp/mailgun_response.txt)
    logger -t sendmail-wrapper "Mailgun API error: HTTP $HTTP_CODE — $RESPONSE"
    rm -f /tmp/mailgun_response.txt
    exit 1
fi

rm -f /tmp/mailgun_response.txt
```

```bash
sudo chmod +x /usr/local/bin/sendmail
```

## Step 5: Install the `mail` Wrapper

```bash
sudo nano /usr/local/bin/mail
```

```bash
#!/bin/bash
MAILGUN_API_KEY="<YOUR_API_KEY>"
MAILGUN_DOMAIN="yourdomain.org"
FROM="noreply@yourdomain.org"
TO="your@email.com"
SUBJECT="AIDE report"

while getopts "s:" opt; do
    case $opt in
        s) SUBJECT="$OPTARG" ;;
    esac
done

BODY=$(cat)
TMPFILE=$(mktemp)
echo "$BODY" > "$TMPFILE"

curl -s --user "api:${MAILGUN_API_KEY}" \
  "https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages" \
  -F from="${FROM}" \
  -F to="${TO}" \
  -F subject="${SUBJECT}" \
  -F "text=<${TMPFILE}"

rm -f "$TMPFILE"
```

```bash
sudo chmod +x /usr/local/bin/mail
```

## Step 6: Install the `mailgun-send` Helper

```bash
sudo nano /usr/local/bin/mailgun-send
```

```bash
#!/bin/bash
MAILGUN_API_KEY="<YOUR_API_KEY>"
MAILGUN_DOMAIN="yourdomain.org"
FROM="noreply@yourdomain.org"

if [ -n "$1" ]; then
    TO="$1"
else
    TO="your@email.com"
fi

INPUT=$(cat)

SUBJECT=$(echo "$INPUT" | grep -m1 "^Subject:" 2>/dev/null | sed 's/Subject: //')
if [ -n "$SUBJECT" ]; then
    BODY=$(echo "$INPUT" | awk 'found{print} /^$/{found=1}')
else
    SUBJECT="System notification from $(hostname)"
    BODY="$INPUT"
fi

if [ -z "$BODY" ]; then
    BODY="$INPUT"
fi

TMPFILE=$(mktemp) || { logger -t sendmail-wrapper "Failed to create temp file"; exit 1; }
echo "$BODY" > "$TMPFILE"

HTTP_CODE=$(curl -s -o /tmp/mailgun_response.txt -w "%{http_code}" \
  --user "api:${MAILGUN_API_KEY}" \
  "https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages" \
  -F from="${FROM}" \
  -F to="${TO}" \
  -F subject="${SUBJECT:-No Subject}" \
  -F "text=<${TMPFILE}")

CURL_EXIT=$?
rm -f "$TMPFILE"

if [ $CURL_EXIT -ne 0 ]; then
    logger -t sendmail-wrapper "curl failed with exit code $CURL_EXIT"
    exit 1
fi

if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    RESPONSE=$(cat /tmp/mailgun_response.txt)
    logger -t sendmail-wrapper "Mailgun API error: HTTP $HTTP_CODE — $RESPONSE"
    rm -f /tmp/mailgun_response.txt
    exit 1
fi

rm -f /tmp/mailgun_response.txt
```

```bash
sudo chmod +x /usr/local/bin/mailgun-send
```

## Step 7: Configure `/etc/aliases`

```bash
sudo nano /etc/aliases
```

```
mailer-daemon: postmaster
postmaster: root
nobody: root
hostmaster: root
usenet: root
news: root
webmaster: root
www: root
ftp: root
abuse: root
noc: root
security: root
root: your@email.com
logcheck: root
```

```bash
sudo newaliases 2>/dev/null || true
```

## Step 8: Install and Configure exim4

exim4 is required as a local MTA even though outbound mail is handled by the wrappers —
several system tools expect a local MTA to exist and log errors if none is present.
Configured for local delivery only (loopback), never relays outbound.

**Why the wrappers win:** system PATH is
`/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin` — `/usr/local/bin/sendmail`
resolves before exim4's `/usr/sbin/sendmail`, so the wrapper is always called first.

```bash
sudo apt install exim4 -y
sudo dpkg-reconfigure exim4-config
```

| Prompt | Value |
|---|---|
| General type of mail configuration | **Local delivery only; not on a network** |
| System mail name | `mail.yourdomain.org` |
| IP-addresses to listen on | `127.0.0.1 ; ::1` |
| Other destinations for which mail is accepted | your server's hostname |
| Keep number of DNS-queries minimal | No |
| Delivery method for local mail | **mbox format in /var/mail/** |
| Split configuration into small files | No |

```bash
sudo update-exim4.conf
sudo systemctl restart exim4
sudo systemctl enable exim4
sudo ss -tlnp | grep exim
```

Expected: `127.0.0.1` and `::1` only.

> `/etc/exim4/passwd.client` is intentionally left empty — only used for smarthost relay,
> which this setup doesn't do.

### Fix the `/usr/sbin/sendmail` symlink

Installing exim4 points `/usr/sbin/sendmail` at itself. `unattended-upgrades` hardcodes
that path rather than searching PATH, bypassing the wrapper. Fix:

```bash
sudo ln -sf /usr/local/bin/sendmail /usr/sbin/sendmail
ls -la /usr/sbin/sendmail   # expect: -> /usr/local/bin/sendmail
```

## Step 9: Set the Mail Hostname

```bash
sudo nano /etc/mailname
```

```
mail.yourdomain.org
```

## Step 10: Configure unattended-upgrades Mail Settings

`/etc/apt/apt.conf.d/50unattended-upgrades` isn't a dpkg conffile — it can be silently
overwritten on package upgrade, losing `Mail`/`MailReport` settings. Store them in a
separate file dpkg won't touch instead (loaded after `50` due to numeric ordering):

```bash
sudo sed -i 's|^Unattended-Upgrade::Mail |//Unattended-Upgrade::Mail |; s|^Unattended-Upgrade::MailReport |//Unattended-Upgrade::MailReport |' /etc/apt/apt.conf.d/50unattended-upgrades
sudo nano /etc/apt/apt.conf.d/51unattended-upgrades-mail
```

```
Unattended-Upgrade::Mail "your@email.com";
Unattended-Upgrade::MailReport "on-change";
```

```bash
sudo chmod 644 /etc/apt/apt.conf.d/51unattended-upgrades-mail
```

## Step 11: Test Each Script

```bash
printf "Subject: sendmail test\n\nThis is a test from sendmail." | sudo /usr/local/bin/sendmail your@email.com
echo "This is a test from the mail wrapper." | sudo /usr/local/bin/mail -s "mail wrapper test"
printf "Subject: mailgun-send test\n\nThis is a test from mailgun-send." | sudo /usr/local/bin/mailgun-send
printf "Subject: custom recipient test\n\nTest." | sudo /usr/local/bin/mailgun-send your@email.com
```

A successful send returns no output. Errors log to syslog:

```bash
sudo journalctl -t sendmail-wrapper --since "5 minutes ago"
```

Test unattended-upgrades end to end:

```bash
sudo sed -i 's/MailReport "on-change"/MailReport "always"/' /etc/apt/apt.conf.d/51unattended-upgrades-mail
sudo unattended-upgrade -v
sudo sed -i 's/MailReport "always"/MailReport "on-change"/' /etc/apt/apt.conf.d/51unattended-upgrades-mail
```

## File Reference

| Path | Purpose |
|---|---|
| `/usr/local/bin/sendmail` | System sendmail replacement |
| `/usr/local/bin/mail` | Mail command replacement — used by AIDE |
| `/usr/local/bin/mailgun-send` | General-purpose sender |
| `/usr/sbin/sendmail` | Symlink → `/usr/local/bin/sendmail` |
| `/etc/aliases` | Routes local Unix account mail to real addresses |
| `/etc/mailname` | Hostname used in mail envelope |
| `/etc/apt/apt.conf.d/51unattended-upgrades-mail` | Mail settings, protected from package upgrades |
| `/etc/exim4/update-exim4.conf.conf` | exim4 config — local delivery only |
| `/etc/exim4/passwd.client` | exim4 relay credentials — intentionally empty |

## Troubleshooting

| Symptom | Likely Cause | Action |
|---|---|---|
| No email, no syslog errors | Message silently dropped | Verify domain verified and `FROM` matches it |
| `HTTP 401` | API key invalid/revoked | Generate new key, update all three scripts |
| `HTTP 403` | Sending domain not verified | Check Mailgun dashboard |
| `curl failed` in syslog | Network unreachable | Check connectivity to `api.mailgun.net` |
| Mail lands in spam | SPF/DKIM not configured | Verify DNS records in Mailgun dashboard |
| exim4 listening publicly | Misconfigured interfaces | Re-run `dpkg-reconfigure exim4-config`, set `127.0.0.1 ; ::1` |
| No MTA available error | exim4 not installed | `sudo apt install exim4 -y`, reconfigure per Step 8 |
| unattended-upgrades sends no mail | `/usr/sbin/sendmail` points to exim4 | `sudo ln -sf /usr/local/bin/sendmail /usr/sbin/sendmail` |
| Mail settings lost after upgrade | Settings were in `50unattended-upgrades` | Move to `51unattended-upgrades-mail` per Step 10 |

---

