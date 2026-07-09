# Yattee Setup Guide

Yattee Server is a self-hosted backend for the Yattee YouTube client (available on iOS, macOS, and tvOS). It proxies YouTube requests and serves video streams, allowing the Yattee app to play content without direct contact with Google's servers. This deployment includes `bgutil-pot`, a proof-of-origin token provider that is required for fetching streams from the Android VR YouTube client — the player client used in this configuration.

---

## Prerequisites

- Docker and Docker Compose installed
- Traefik running with the external Docker network created and in use
- A DNS record pointing your chosen subdomain at the host (e.g. `yattee.yourdomain.org`)
- Traefik `fileConfig.yml` configured with a `yattee` router and service
- Internet access from the host for YouTube API requests

---

## Directory Structure

```
yattee/
  compose.yml
  yattee.dockerfile
  yt-dlp.conf
  .env
```

Unlike most services in this stack, Yattee Server is built from a local Dockerfile rather than pulled as a pre-built image.

---

## Step 1 - Review the Dockerfile

```dockerfile
FROM yattee/yattee-server:latest
RUN pip install -U bgutil-ytdlp-pot-provider
```

The Dockerfile extends the upstream `yattee-server` image and installs the `bgutil-ytdlp-pot-provider` Python package. This package registers `bgutil-pot` as a proof-of-origin token provider for `yt-dlp`, which Yattee Server uses under the hood for stream extraction.

The image is built locally with host networking (`network: host`) to allow the build step to reach the internet:

```yaml
build:
  context: "."
  dockerfile: yattee.dockerfile
  network: host
```

No pre-built image is pulled for the Yattee service itself — Docker Compose will build it on first `up`.

---

## Step 2 - Review the yt-dlp Configuration

The `yt-dlp.conf` file is mounted into the container at `/root/.config/yt-dlp/config`:

```
--extractor-args "youtube:player_client=android_vr"
```

This forces `yt-dlp` to use the Android VR player client when extracting YouTube streams. The `bgutil-pot` sidecar is required when using this client because Google requires a proof-of-origin token for this access method.

Do not change this without also adjusting the `bgutil-pot` dependency accordingly.

---

## Step 3 - Create the .env File

Create `yattee/.env` and set any required environment variables. Consult the [Yattee Server documentation](https://github.com/yattee/yattee) for the full list of supported environment variables:

```env
# Example — check Yattee Server documentation for all supported variables
INVIDIOUS_COMPANION=
YT_DLP_PATH=/usr/local/bin/yt-dlp
```

---

## Step 4 - Review the Compose File

```yaml
services:
  yattee-server:
    build:
      context: "."
      dockerfile: yattee.dockerfile
      network: host
    container_name: yattee-server
    volumes:
      - yattee_downloads:/downloads
      - yattee_data:/app/data
      - ./yt-dlp.conf:/root/.config/yt-dlp/config:ro
    env_file: .env
    environment:
      - LOG_LEVEL=WARNING
    extra_hosts:
      - "host.docker.internal:host-gateway"
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    networks:
      - proxy-net
      - yattee-net
    restart: unless-stopped
    mem_limit: 512m
    memswap_limit: 762m
    depends_on:
      - bgutil-pot

  bgutil-pot:
    image: brainicism/bgutil-ytdlp-pot-provider:latest
    container_name: bgutil-pot
    restart: unless-stopped
    mem_limit: 256m
    memswap_limit: 300m
    ports:
      - "4416:4416"
    networks:
      - yattee-net

volumes:
  yattee_downloads:
  yattee_data:

networks:
  proxy-net:
    external: true
    name: proxy-net
  yattee-net:
```

**Service dependencies**

`yattee-server` depends on `bgutil-pot`. Docker Compose will start `bgutil-pot` first. `bgutil-pot` exposes port 4416 on both the host and within the `yattee-net` internal network.

**Networks**

- `proxy-net` (external) — connects `yattee-server` to Traefik
- `yattee-net` (internal) — isolates communication between `yattee-server` and `bgutil-pot`

`bgutil-pot` is only on `yattee-net` and is not accessible from the shared external network. It is also exposed on the host on port 4416, which may be useful for debugging but should be firewalled if the host is public-facing.

**Host gateway**

```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

This makes the host machine reachable from inside the `yattee-server` container at `host.docker.internal`. This is needed if Yattee Server needs to reach other services on the host (such as AdGuard for DNS) or if any configuration references the host directly.

**Volumes**

- `yattee_downloads` — persists downloaded media files across container restarts
- `yattee_data` — persists Yattee Server application data

Both are named Docker volumes managed by Compose.

**Log rotation**

```yaml
max-size: "10m"
max-file: "3"
```

Logs are rotated at 10 MB with up to 3 files kept, for a maximum of 30 MB of log data.

---

## Step 5 - Build and Start the Stack

On first run, Docker will build the `yattee-server` image:

```bash
cd yattee/
docker compose up -d --build
```

The `--build` flag is only required on the first run or after changes to `yattee.dockerfile` or `yt-dlp.conf`. Subsequent starts can omit it:

```bash
docker compose up -d
```

Check both containers:

```bash
docker logs yattee-server
docker logs bgutil-pot
```

---

## Step 6 - Verify the Traefik Configuration

In `traefik/config/fileConfig.yml`:

```yaml
routers:
  yattee:
    entryPoints:
      - https
    rule: "Host(`yattee.yourdomain.org`)"
    middlewares:
      - securityHeaders@file
      - local-ipwhitelist@file
      - compress@file
    service: yattee

services:
  yattee:
    loadBalancer:
      servers:
        - url: http://yattee-server:8085
      passHostHeader: true
```

Yattee Server listens on port 8085 internally. Traefik resolves it by container name since both share the shared external network.

---

## Step 7 - Configure the Yattee App

In the Yattee app (iOS/macOS/tvOS), navigate to settings and set the Invidious or Piped instance URL to your server:

```
https://yattee.yourdomain.org
```

The app will use your self-hosted backend for all content requests.

---

## Resource Limits

| Container | RAM Limit | Swap Limit |
|---|---|---|
| yattee-server | 512 MB | 762 MB |
| bgutil-pot | 256 MB | 300 MB |

---

## Notes

- The `bgutil-pot` container handles token generation for the Android VR player client. If it is not running, `yt-dlp` will fail to extract streams. Always ensure `bgutil-pot` starts before `yattee-server` — the `depends_on` directive handles this.
- `LOG_LEVEL=WARNING` suppresses informational logs. Change to `INFO` or `DEBUG` temporarily when troubleshooting stream extraction failures.
- The `yt-dlp.conf` file is mounted read-only (`:ro`). To change the player client or add other `yt-dlp` flags, edit the file on the host and restart the container.
- YouTube's internal APIs change frequently. If streams stop working, the first step is to update both the `yattee-server` image and the `bgutil-ytdlp-pot-provider` package by rebuilding the image:

```bash
docker compose build --no-cache
docker compose up -d
```
