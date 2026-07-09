# Docker Compose Auto-Update with AIDE — Setup Guide

Referenced from [`server-hardening.md`](server-hardening.md) Section 21's docker-update.timer
entry. Requires [`monitoring-aide-logcheck-logdy.md`](monitoring-aide-logcheck-logdy.md) (AIDE part)
installed and initialised.

## Overview

Nightly unattended update for Docker Compose projects: pulls latest images for
image-based containers, rebuilds locally-built images, tears down and redeploys with full
Compose config, prunes dangling images, and updates the AIDE database to reflect the new
system state.

Three files:
- `/opt/docker-update.sh` — the script
- `/etc/systemd/system/docker-update.service`
- `/etc/systemd/system/docker-update.timer`

Logs to `/var/log/docker-update.log`.

## Prerequisites

- Docker and Docker Compose v2
- AIDE installed and initialised ([`monitoring-aide-logcheck-logdy.md`](monitoring-aide-logcheck-logdy.md))
- Compose projects under `/opt/appdata/`
- Script runs as root

## 1. The Update Script

```bash
sudo nano /opt/docker-update.sh
```

```bash
#!/bin/bash
# /opt/docker-update.sh
# Updates all Docker Compose projects, destroys containers before redeploy,
# and handles Yattee which requires a local Dockerfile build.

LOG="/var/log/docker-update.log"

# ── Standard Compose projects (image-based) ───────────────────────────────────
COMPOSE_PROJECTS=(
  "/opt/appdata/adguard"
  "/opt/appdata/redlib"
  "/opt/appdata/searxng"
  "/opt/appdata/traefik"
  "/opt/appdata/yarr"
)

# ── Yattee: locally built image ───────────────────────────────────────────────
BUILD_PROJECT_DIR="/opt/appdata/yattee"

# ─────────────────────────────────────────────────────────────────────────────

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

log "=========================================="
log "Starting Docker update run"
log "=========================================="

# ── Helper: destroy + redeploy a standard compose project ────────────────────
# Compose filename is always compose.yaml — no fallback, naming is enforced.
update_project() {
  local PROJECT_DIR="$1"
  local COMPOSE_FILE="$PROJECT_DIR/compose.yaml"

  if [ ! -f "$COMPOSE_FILE" ]; then
    log "SKIP: No compose file found at $COMPOSE_FILE"
    return
  fi

  log "Checking: $PROJECT_DIR"

  PULL_OUTPUT=$(docker compose -f "$COMPOSE_FILE" pull 2>&1)
  echo "$PULL_OUTPUT" >> "$LOG"

  if echo "$PULL_OUTPUT" | grep -q "Pull complete\|Downloaded newer image"; then
    log "Update found — tearing down $PROJECT_DIR"
    docker compose -f "$COMPOSE_FILE" down >> "$LOG" 2>&1

    log "Redeploying $PROJECT_DIR"
    docker compose -f "$COMPOSE_FILE" up -d >> "$LOG" 2>&1

    log "Done: $PROJECT_DIR"
  else
    log "No changes: $PROJECT_DIR"
  fi
}

# ── Helper: destroy + rebuild Yattee (locally built image) ───────────────────
update_build_project() {
  local PROJECT_DIR="$1"
  local COMPOSE_FILE="$PROJECT_DIR/compose.yaml"

  if [ ! -f "$COMPOSE_FILE" ]; then
    log "SKIP: No compose file found at $COMPOSE_FILE"
    return
  fi

  log "Yattee: tearing down $PROJECT_DIR"
  docker compose -f "$COMPOSE_FILE" down >> "$LOG" 2>&1

  log "Yattee: rebuilding image"
  docker compose -f "$COMPOSE_FILE" build >> "$LOG" 2>&1

  log "Yattee: redeploying"
  docker compose -f "$COMPOSE_FILE" up -d >> "$LOG" 2>&1

  log "Done: $PROJECT_DIR"
}

# ── Run standard projects ─────────────────────────────────────────────────────
for PROJECT_DIR in "${COMPOSE_PROJECTS[@]}"; do
  update_project "$PROJECT_DIR"
done

# ── Run Yattee ────────────────────────────────────────────────────────────────
update_build_project "$BUILD_PROJECT_DIR"

# ── Prune dangling images & build cache left behind after rebuilds ────────────
log "Pruning dangling images..."
docker image prune -af >> "$LOG" 2>&1

log "Pruning build cache..."
docker builder prune -af >> "$LOG" 2>&1

log "All projects processed."

# ── Update AIDE database after container changes ──────────────────────────────
log "Running AIDE database update..."
aide --update --config /etc/aide/aide.conf >> "$LOG" 2>&1
AIDE_EXIT=$?

if [ $AIDE_EXIT -eq 1 ]; then
  log "ERROR: AIDE encountered errors (exit $AIDE_EXIT) — manual review required"
else
  log "AIDE finished (exit $AIDE_EXIT) — swapping in new database"
  mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db >> "$LOG" 2>&1 \
    && chown _aide:root /var/lib/aide/aide.db \
    && chmod 600 /var/lib/aide/aide.db \
    && log "AIDE database swapped and ownership restored successfully" \
    || log "ERROR: Failed to swap AIDE database — manual intervention required"
fi
```

```bash
sudo chmod +x /opt/docker-update.sh
```

### Customizing

**Standard projects** — edit `COMPOSE_PROJECTS`, one path per directory. Each must contain
a `compose.yaml` file — no other filename is checked.

**Locally built projects** — set `BUILD_PROJECT_DIR`. `update_build_project` always
tears down and rebuilds unconditionally (local builds can't be checked against a
registry). For more than one, call it once per directory before the prune step:

```bash
update_build_project "/opt/appdata/project-a"
update_build_project "/opt/appdata/project-b"
```

**Compose filename detection** is automatic (`compose.yml` → `compose.yaml` →
`docker-compose.yml` → `docker-compose.yaml`, first match wins).

## 2. Systemd Service Unit

```bash
sudo nano /etc/systemd/system/docker-update.service
```

```ini
[Unit]
Description=Docker Compose Update
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=/opt/docker-update.sh
```

## 3. Systemd Timer Unit

```bash
sudo nano /etc/systemd/system/docker-update.timer
```

```ini
[Unit]
Description=Run Docker Compose Update daily at 4 AM

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

`Persistent=true` — if the machine was off at 4 AM, the timer fires shortly after next
boot instead of skipping that run.

## 4. Enable and Start

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now docker-update.timer
sudo systemctl list-timers docker-update.timer
```

## 5. Test the Script

```bash
sudo /opt/docker-update.sh && sudo tail -80 /var/log/docker-update.log
```

A successful run ends with:

```
AIDE finished (exit N) — swapping in new database
AIDE database swapped successfully
All projects processed.
```

## AIDE Exit Codes

| Exit code | Meaning | Script action |
|-----------|---------|---------------|
| 0 | No differences found | Swap database |
| 1 | Error during run | Log error, skip swap |
| 2-7 | Differences found (normal after updates) | Swap database |

Exit codes 2-7 are expected after every run — container activity changes files under
`/var/lib/docker` and log timestamps. Not errors.

## Log Location

```bash
sudo tail -f /var/log/docker-update.log
sudo journalctl -u docker-update.service -n 50
```

---

