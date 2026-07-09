# SearXNG Setup Guide

SearXNG is a self-hosted, privacy-respecting metasearch engine that aggregates results from multiple search engines without tracking users. This setup uses Valkey (a Redis-compatible cache) as a session backend, connects SearXNG to the shared external network for Traefik routing, and mounts a local settings directory for full configuration control.

---

## Prerequisites

- Docker and Docker Compose installed
- Traefik running with the external Docker network created and in use
- A DNS record pointing your chosen subdomain at the host (e.g. `search.yourdomain.org`)
- Traefik `fileConfig.yml` configured with a `searxng` router and service

---

## Directory Structure

```
searxng/
  compose.yaml
  settings/
    settings.yml
    favicons.toml
```

The `settings/` directory is mounted into the container at `/etc/searxng`. SearXNG reads its configuration from `settings.yml` at startup. The `favicons.toml` file configures the favicon proxy.

---

## Step 1 - Review and Customize settings.yml

The `settings.yml` file controls every aspect of SearXNG behavior including enabled search engines, UI defaults, result filtering, and the connection to the Valkey cache.

**Base URL**

The base URL must match your public-facing domain:

```yaml
server:
  base_url: https://search.yourdomain.org
```

Update this to your own domain before starting the stack. SearXNG uses this value to construct internal links and for CSRF protection.

**Secret key**

SearXNG requires a secret key for signing sessions. Generate one and set it:

```bash
openssl rand -hex 32
```

Place the output in `settings.yml`:

```yaml
server:
  secret_key: "your_generated_secret_key_here"
```

Do not use a default or empty value in production.

**Redis / Valkey connection**

```yaml
redis:
  url: redis://searxng-redis:6379
```

The Valkey container is named `searxng-redis` and both containers share the internal `searxng` Docker network. This connection is used for limiter state and caching.

**Search engines**

Review the `engines` section and enable or disable engines according to your preferences. Engines that require API keys must be configured with those keys in `settings.yml`.

---

## Step 2 - Review the Compose File

```yaml
services:
  searxng-redis:
    container_name: searxng-redis
    image: docker.io/valkey/valkey:8-alpine
    command: valkey-server --save 30 1 --loglevel warning
    restart: unless-stopped
    networks:
      - searxng
    volumes:
      - valkey-data:/data
    cap_drop:
      - ALL
    cap_add:
      - SETGID
      - SETUID
      - DAC_OVERRIDE
    logging:
      driver: json-file
      options:
        max-size: 1m
        max-file: "1"
    mem_limit: 128m
    memswap_limit: 192m

  searxng:
    container_name: searxng
    image: docker.io/searxng/searxng:latest
    restart: unless-stopped
    networks:
      - proxy-net
      - searxng
    volumes:
      - ./settings:/etc/searxng:rw
    environment:
      - SEARXNG_BASE_URL=https://search.yourdomain.org
      - UWSGI_WORKERS=2
      - UWSGI_THREADS=2
    cap_add:
      - CHOWN
      - SETGID
      - SETUID
    logging:
      driver: json-file
      options:
        max-size: 1m
        max-file: "1"
    mem_limit: 512m
    memswap_limit: 640m

networks:
  proxy-net:
    external: true
    name: proxy-net
  searxng:

volumes:
  valkey-data:
```

**Network design**

Two networks are used:

- `proxy-net` (external) — connects SearXNG to Traefik for external routing
- `searxng` (internal) — isolates communication between SearXNG and Valkey; Valkey is not exposed to the broader shared network

**Workers and threads**

```yaml
UWSGI_WORKERS=2
UWSGI_THREADS=2
```

This runs 4 concurrent request handlers (2 workers x 2 threads). Increase these values on hosts with more CPU cores and if you expect heavier usage.

**Base URL environment variable**

```yaml
SEARXNG_BASE_URL=https://search.yourdomain.org
```

Update this to match your domain. It must match `server.base_url` in `settings.yml`.

**Valkey persistence**

```yaml
command: valkey-server --save 30 1 --loglevel warning
```

Valkey is configured to save a snapshot every 30 minutes if at least 1 key changed. Cache data is stored in the `valkey-data` named volume and survives container restarts.

---

## Step 3 - Set Directory Permissions

SearXNG writes to the mounted `settings/` directory (mounted as `rw`). The container process runs under a specific UID. If you encounter permission errors on startup, check the ownership of the `settings/` directory and adjust if necessary:

```bash
ls -la searxng/settings/
```

If needed, make the directory world-writable (acceptable since this is a private VPS):

```bash
chmod -R 777 searxng/settings/
```

---

## Step 4 - Start the Stack

```bash
cd searxng/
docker compose up -d
```

Valkey will start first, followed by SearXNG. Check both containers:

```bash
docker logs searxng-redis
docker logs searxng
```

---

## Step 5 - Verify the Traefik Configuration

In `traefik/config/fileConfig.yml`:

```yaml
routers:
  searxng:
    entryPoints:
      - https
    rule: "Host(`search.yourdomain.org`)"
    middlewares:
      - securityHeaders@file
      - local-ipwhitelist@file
      - compress@file
    service: searxng

services:
  searxng:
    loadBalancer:
      servers:
        - url: http://searxng:8080
      passHostHeader: true
```

SearXNG listens on port 8080 internally. Traefik resolves it by container name since both are on the shared external network.

---

## Step 6 - Test Access

Navigate to your configured subdomain:

```
https://search.yourdomain.org
```

Perform a test search to confirm results are returned from multiple engines. If results are missing from specific engines, check `docker logs searxng` for engine-level error messages.

---

## Resource Limits

| Container | RAM Limit | Swap Limit |
|---|---|---|
| searxng | 512 MB | 640 MB |
| searxng-redis | 128 MB | 192 MB |

---

## Notes

- Log files for both containers are capped at 1 MB with a single backup file (`max-file: "1"`), keeping disk usage low.
- Valkey is only reachable from the `searxng` internal network. It is not exposed on the shared external network or the host.
- If you change `settings.yml` while the container is running, restart SearXNG to apply the changes: `docker compose restart searxng`.
- The `favicons.toml` file configures SearXNG's favicon proxy, which fetches and caches favicons for search results. Review it if you want to disable or adjust favicon fetching behavior.
