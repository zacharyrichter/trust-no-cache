# ntfy: this host's own alerting

Config: [`configs/ntfy/`](../../configs/ntfy/), [`ntfy-sendmail`](../../configs/host/usr/local/bin/ntfy-sendmail)

## Purpose

The VPS's own notification server. Every alert from this host (integrity checks, package updates, Docker updates, cron output) is delivered here, so alerts don't depend on the home network being up.

## Why it's built this way

- **Separate from the home ntfy**, so a home outage can't silence the VPS's alerts.
- **Closed by default.** `auth-default-access: deny-all` and no sign-up. Publishing and subscribing both need an account or a token.
- **Reached only through Traefik**, behind the IP allowlist. No ports are published.
- **Existing tools need no changes.** `/usr/sbin/sendmail` is a symlink to `ntfy-sendmail`, so unattended-upgrades, cron and `docker-update` deliver here without any ntfy-specific code.

## Current state

**Container** ([`compose.yaml`](../../configs/ntfy/compose.yaml)): runs as `1000:1000`, read-only root with tmpfs `/tmp`, `cap_drop: ALL`, `no-new-privileges`, 128 MB memory, a health check on `/v1/health`, fixed address `172.18.0.7` on `warpconduit`. No published ports.

**`server.yml`** (not in this repo): `base-url` is the public hostname, `behind-proxy: true`, cache in `data/cache.db`, auth in `data/auth.db`, `deny-all` default access, sign-up off, login on, and `upstream-base-url: https://ntfy.sh` so iOS clients receive instant push. That upstream setting sends only a message identifier through ntfy.sh's push relay; message content stays on this server.

**Who sends here:** the notifications table in [vps-host-hardening.md](../vps-host-hardening.md#notifications). Every sender reads the URL and token from `/etc/ntfy-sendmail.env` (root, mode 600, per host). The shim caps the body at 3500 bytes because ntfy rejects bodies over 4096.

## Procedure

Users and access rules are managed inside the container:

```bash
sudo docker exec -it ntfy ntfy user list
sudo docker exec -it ntfy ntfy access
```

## Verification

```bash
sudo docker ps --filter name=ntfy --format '{{.Status}}'      # Up ... (healthy)
printf 'Subject: Test from the VPS\n\nntfy reachable.\n' | sudo /usr/sbin/sendmail -oi -t; echo "exit $?"
```

## Recovery

- **Alerts stop arriving:** check the container, then the Traefik route, then the token in `/etc/ntfy-sendmail.env`.
- **Rebuild material:** `server.yml`, `compose.yaml` and `data/auth.db` (accounts, tokens, access rules). `cache.db` holds only recent messages. After a rebuild without `auth.db`, recreate the accounts, access rules and a token with `ntfy user`, `ntfy access` and `ntfy token`, then sign phones in again.
