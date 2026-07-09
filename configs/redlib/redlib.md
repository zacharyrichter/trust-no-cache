# Redlib Setup Guide

Redlib is a privacy-respecting alternative frontend for Reddit. It fetches Reddit content server-side and presents it without tracking scripts, ads, or JavaScript requirements. In this stack it runs as a locked-down container on the shared external network and is routed through Traefik.

---

## Prerequisites

- Docker and Docker Compose installed
- Traefik running with the external Docker network created and in use
- A DNS record pointing your chosen subdomain at the host (e.g. `redlib.yourdomain.org`)
- Traefik `fileConfig.yml` configured with a `redlib` router and service entry

---

## Directory Structure

```
redlib/
  compose.yml
  .env
```

There are no mounted volumes. Redlib is stateless — all configuration is provided through environment variables.

---

## Step 1 - Create the .env File

Redlib is configured entirely through environment variables loaded from a `.env` file. Create `redlib/.env` and set any options you want to customize. Common variables include:

```env
REDLIB_DEFAULT_THEME=system
REDLIB_DEFAULT_FRONT_PAGE=default
REDLIB_DEFAULT_LAYOUT=card
REDLIB_DEFAULT_SHOW_NSFW=false
REDLIB_DEFAULT_USE_HLS=false
REDLIB_DEFAULT_HIDE_HLS_NOTIFICATION=false
REDLIB_DEFAULT_AUTOPLAY_VIDEOS=false
REDLIB_DEFAULT_SUBSCRIPTIONS=
REDLIB_BANNER=
REDLIB_ROBOTS_DISABLE_INDEXING=true
```

The full list of supported variables is available in the Redlib documentation. At minimum, an empty `.env` file must exist, as the compose file specifies:

```yaml
env_file:
  - path: ./.env
```

---

## Step 2 - Review the Compose File

```yaml
services:
  redlib:
    image: quay.io/redlib/redlib:latest
    restart: always
    container_name: redlib
    user: nobody
    read_only: true
    security_opt:
      - no-new-privileges=true
    cap_drop:
      - ALL
    env_file:
      - path: ./.env
    networks:
      - proxy-net
    healthcheck:
      disable: true
    mem_limit: 256m
    memswap_limit: 512m

networks:
  proxy-net:
    external: true
    name: proxy-net
```

This compose file applies an unusually strict security posture:

- `user: nobody` — the container process runs as the unprivileged `nobody` user
- `read_only: true` — the container filesystem is mounted read-only, preventing any writes inside the container
- `cap_drop: ALL` — all Linux capabilities are dropped
- `no-new-privileges: true` — prevents privilege escalation via setuid binaries
- `healthcheck: disable: true` — the built-in health check is disabled, which is acceptable since Traefik handles routing and availability

> The upstream image used here is `quay.io/redlib/redlib:latest`. Confirm that the image works with `read_only: true` and `user: nobody` settings before deploying, as some images require writable temp directories.

---

## Step 3 - Verify the Traefik Configuration

In `traefik/config/fileConfig.yml`, confirm the redlib router and service are present:

```yaml
routers:
  redlib:
    entryPoints:
      - https
    rule: "Host(`redlib.yourdomain.org`)"
    middlewares:
      - securityHeaders@file
      - local-ipwhitelist@file
      - compress@file
    service: redlib

services:
  redlib:
    loadBalancer:
      servers:
        - url: http://redlib:8080
      passHostHeader: true
```

Traefik resolves `redlib` by container name because both Traefik and Redlib are on the shared external Docker network. Redlib listens on port 8080 internally.

---

## Step 4 - Start Redlib

```bash
cd redlib/
docker compose up -d
```

Check the logs to confirm startup:

```bash
docker logs redlib
```

Redlib does not require any initialization steps. It is available immediately after the container starts.

---

## Step 5 - Test Access

Navigate to your configured subdomain in a browser:

```
https://redlib.yourdomain.org
```

If you have the IP allowlist middleware enabled in Traefik, access must come from one of the allowed IP ranges. Access from outside those ranges will be blocked at the proxy level.

---

## Resource Limits

```yaml
mem_limit: 256m
memswap_limit: 512m
```

Redlib is a lightweight service. 256 MB is sufficient for normal usage. Increase this if you expect high concurrent traffic.

---

## Notes

- Redlib has no persistent state and no database. Restarting or recreating the container has no effect on data because there is none.
- Reddit occasionally changes its internal API in ways that break Redlib. If the frontend stops loading content, check for an updated image.
- The `restart: always` policy means the container restarts even if you stop it manually via `docker compose stop`. Use `docker compose down` to stop it cleanly.
- Because all capabilities are dropped and the filesystem is read-only, this service cannot write logs to disk. Logs are only available via `docker logs redlib`.
