# FreshRSS: personal feed reader

Config: [`configs/freshrss/`](../../configs/freshrss/)

## Purpose

A personal RSS reader. Unlike the other services it is for one person: access needs a FreshRSS account, and only one exists.

## Why it's built this way

- **It runs on the VPS** so feeds keep updating whatever the state of the home network.
- **Two layers of access control.** Traefik's IP allowlist like every other service, plus FreshRSS's own login.
- **Fixed address** (`172.18.0.50`) on `warpconduit`. `TRUSTED_PROXY` is Traefik's address only (`172.18.0.2/32`), so client addresses are taken from Traefik's headers and nowhere else.
- **Locked down as far as the image allows.** `cap_drop: ALL` with only `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `KILL`, `SETUID`, `SETGID` and `NET_BIND_SERVICE` added back, `no-new-privileges`, 256 MB of memory with no swap, and a 200-process limit.
- **Not read-only, by necessity.** With `read_only: true` the container fails to start, because the image's entrypoint rewrites time zone, PHP, Apache and cron configuration under `/etc` and `/var` on every start. tmpfs mounts can't fix that without hiding the image's own configuration. A comment in `compose.yaml` records the test.

## Current state

[`compose.yaml`](../../configs/freshrss/compose.yaml): feeds refresh at :03 and :33 past each hour (`CRON_MIN`), and a health check runs the image's `cli/health.php`. Volumes are `data/` (configuration, users, the SQLite database, cache) and `extensions/`.

## Verification

```bash
sudo docker ps --filter name=freshrss --format '{{.Status}}'   # Up ... (healthy)
curl -m5 http://172.18.0.50 ; echo "exit $?"                   # from a WireGuard client: times out, exit 28
```

The second check should *fail*: a client must go through Traefik, not straight to the container.

## Recovery

Everything that matters is in `data/` (notably `data/users/<user>/db.sqlite`), plus `compose.yaml` and any custom extensions. Without `data/`, set up the account and feeds again.
