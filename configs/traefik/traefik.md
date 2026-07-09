# Traefik Setup Guide

Traefik is the reverse proxy that sits in front of all other services. It terminates TLS, routes incoming HTTPS traffic by hostname, enforces security headers, and issues certificates automatically via Let's Encrypt using a Cloudflare DNS challenge. All other services in this stack depend on Traefik being up and connected to the shared external Docker network.

---

## Prerequisites

- Docker and Docker Compose installed on the host
- A domain name with DNS managed through Cloudflare
- A Cloudflare API token with `Zone:DNS:Edit` permission for your domain
- Port 443 open and reachable on the host
- The external Docker network created before starting (see Step 1)

---

## Directory Structure

```
traefik/
  compose.yml
  .env
  config/
    traefik.yml
    fileConfig.yml
    acme.json       # created manually before first run
    logs/           # created manually before first run
```

---

## Step 1 - Create the External Network

All services in this stack share an external Docker network. Create it once:

```bash
docker network create proxy-net
```

This only needs to be done once on the host. Every compose stack that references this network as an external network will attach to it. Use a consistent name across all compose files.

---

## Step 2 - Prepare the Config Directory

Traefik's config is mounted from a host directory into `/etc/traefik/` inside the container, as defined in `compose.yml`:

```yaml
volumes:
  - /opt/docker/traefik/config:/etc/traefik/
```

Create the directory and place `traefik.yml` and `fileConfig.yml` inside it:

```bash
sudo mkdir -p /opt/docker/traefik/config/logs
sudo touch /opt/docker/traefik/config/acme.json
sudo chmod 600 /opt/docker/traefik/config/acme.json
```

The `acme.json` file stores Let's Encrypt certificates. It must exist before Traefik starts and must be readable only by the owner (mode `600`); Traefik will refuse to run if permissions are too open.

---

## Step 3 - Configure traefik.yml

The main configuration file sets up entry points, logging, providers, and the certificate resolver.

Key settings to review and adjust:

**Entry point**

```yaml
entryPoints:
  https:
    address: :443
```

Only HTTPS (port 443) is exposed. HTTP is not configured. Ensure port 443 is bound correctly on your host.

**Trusted IPs for forwarded headers**

```yaml
forwardedHeaders:
  trustedIPs:
    - "172.16.0.0/12"
```

This tells Traefik to trust `X-Forwarded-*` headers from the Docker bridge subnet.

```bash
This CIDR covers the entire docker network RFC range.
```

**TLS via Let's Encrypt (DNS challenge)**

```yaml
certificatesResolvers:
  letsencrypt:
    acme:
      email: your@email.com
      storage: /etc/traefik/acme.json
      dnsChallenge:
        provider: cloudflare
        disablePropagationCheck: true
        delayBeforeCheck: 60s
```

Replace `email` with your own. The `cloudflare` provider reads the API token from the `CF_DNS_API_TOKEN` environment variable supplied in `.env`.

**Wildcard certificate**

```yaml
domains:
  - main: yourdomain.org
    sans:
      - '*.yourdomain.org'
```

Replace with your own domain. The wildcard SAN covers all subdomains with a single certificate.

**Log files**

```yaml
log:
  filePath: "/etc/traefik/logs/traefik.log"
accessLog:
  filePath: "/etc/traefik/logs/access.log"
```

Logs are written inside the mounted config directory and persist on the host.

---

## Step 4 - Configure fileConfig.yml

The file provider (`fileConfig.yml`) defines all HTTP routers, services, and middleware. Traefik watches this file and reloads it live without a restart.

**Routers**

Each service gets a router that matches on hostname:

```yaml
routers:
  adguard:
    rule: "Host(`adguard.yourdomain.org`)"
    service: adguard
    middlewares:
        - secured-chain@file
        - adguard-auth@file
```

Replace hostnames to match your domain. Remove or add routers for each service you deploy.

**Services**

Services point Traefik at the backend container or IP:

```yaml
services:
  adguard:
    loadBalancer:
      servers:
        - url: http://<docker-bridge-ip>:3000
  redlib:
    loadBalancer:
      servers:
        - url: http://redlib:8080
```

AdGuard runs in host network mode, so it is addressed by the host's IP on the Docker bridge. Find your bridge gateway IP with:

```bash
docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}'
```

All other services are addressed by container name because they share the external Docker network.

**IP allowlist middleware**

```yaml
local-ipwhitelist:
  ipAllowList:
    sourceRange:
      - "172.16.0.0/12"    # Docker bridge subnet
      - "10.8.0.0/24"      # WireGuard VPN subnet
      - "<YOUR_STATIC_IP>/32"
```

All services are restricted to local and VPN subnets. Add your own IP ranges here. Remove any entries that do not apply to your setup.

**Basic auth on AdGuard**

```yaml
adguard-auth:
  basicAuth:
    users:
      - "username:<BCRYPT_HASH>"
```

Generate a bcrypt-hashed password and replace the entry:

```bash
htpasswd -nB username
```
** Proxy headers**

```yaml
    # Strip client-supplied forwarded headers before they reach upstream
    strip-proxy-headers:
      headers:
        customRequestHeaders:
          X-Real-IP: ""
          X-Forwarded-For: ""
          X-Forwarded-Host: ""
          X-Forwarded-Proto: "https" # Forces your apps to see the connection as secure
```          
**Rate limiting**

```yaml
    rate-limit:
      rateLimit:
        average: 100
        burst: 50
        period: 1s
```


**Security headers**

```yaml
    securityHeaders:
      headers:
    # HSTS Settings
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        stsPreload: true
        forceSTSHeader: true
    # Security Policies
        contentTypeNosniff: true
        browserXssFilter: true
        referrerPolicy: "strict-origin-when-cross-origin"
        frameDeny: false
        customFrameOptionsValue: "SAMEORIGIN"
    # Information Concealment & Permissions
        customResponseHeaders:
          Server: "" # Hides Traefik version
          X-DNS-Prefetch-Control: "off"
          X-Robots-Tag: "none,noarchive,nosnippet,notranslate,noimageindex"
          Permissions-Policy: "microphone=(), camera=(), payment=(), geolocation=()"
          # Cross-Origin Isolation (Spectre/Meltdown Protection)
          Cross-Origin-Opener-Policy: "same-origin"
          Cross-Origin-Embedder-Policy: "unsafe-none"
          Cross-Origin-Resource-Policy: "same-site"
```

HSTS is set to one year with preload. This is appropriate for production. Do not enable preload unless you intend to submit your domain to the HSTS preload list.

**Performance**

```yaml
    compress:
      compress: {}
```

**The master chain**

```yaml
    # This is what you apply to your routers.
    # It executes in the order of: Clean -> Authorize -> Secure -> Compress
    secured-chain:
      chain:
        middlewares:
          - strip-proxy-headers
          - local-ipwhitelist # Make sure this is defined in your file
          - rate-limit
          - securityHeaders
          - compress
```

**TLS minimum version**

```yaml
tls:
  options:
    default:
      minVersion: VersionTLS13
      sniStrict: true
      curvePreferences:
        - CurveP521
        - CurveP384
        - CurveP256
```

Only TLS 1.3 is accepted. This is a strong setting that drops compatibility with very old clients.

---

## Step 5 - Create the .env File

Create a `.env` file in the `traefik/` directory:

```env
CF_DNS_API_TOKEN=<YOUR_CLOUDFLARE_API_TOKEN>
```

The compose file passes this variable directly into the container:

```yaml
environment:
  CLOUDFLARE_DNS_API_TOKEN: ${CF_DNS_API_TOKEN}
```

---

## Step 6 - Start Traefik

```bash
cd traefik/
docker compose up -d
```

Check that it started correctly:

```bash
docker logs traefik
```

Watch for ACME certificate issuance in the logs. The first run will request a certificate from Let's Encrypt. If the DNS challenge fails, verify that the Cloudflare API token has the correct permissions and that your DNS records are propagated.

---

## Resource Limits

```yaml
mem_limit: 256m
memswap_limit: 320m
```

Traefik is kept to 256 MB of RAM. This is sufficient for a small number of services.

---

## Notes

- The Traefik dashboard is disabled (`dashboard: false`). To enable it temporarily for debugging, set it to `true` and add a router in `fileConfig.yml`, but restrict access carefully.
- Anonymous usage reporting is disabled (`sendAnonymousUsage: false`).
- The CrowdSec bouncer middleware is present in the config but commented out. To enable it, deploy a CrowdSec bouncer container and uncomment the relevant lines.
- The external Docker network must exist before any compose stack references it. Always create it first.
