#!/bin/bash
# /opt/docker-update.sh
# Auto-discovers Docker Compose projects under /opt/appdata, updates each,
# and detects build-based projects (any project with a build: key) automatically via their compose.yaml.

LOG="/var/log/docker-update.log"

START_LINE=$( [ -f "$LOG" ] && wc -l < "$LOG" || echo 0 )

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

log "=========================================="
log "Starting Docker update run"
log "=========================================="

# ── Helper: destroy + redeploy a standard (image-based) compose project ──────
update_project() {
  local PROJECT_DIR="$1"
  local COMPOSE_FILE="$PROJECT_DIR/compose.yaml"

  log "Checking (pull): $PROJECT_DIR"

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

# ── Helper: destroy + rebuild a build-based compose project (any project with a build: key) ────
update_build_project() {
  local PROJECT_DIR="$1"
  local COMPOSE_FILE="$PROJECT_DIR/compose.yaml"

  log "Checking (build): $PROJECT_DIR"

  log "Pulling non-build images for $PROJECT_DIR"
  docker compose -f "$COMPOSE_FILE" pull --ignore-buildable >> "$LOG" 2>&1

  log "Tearing down $PROJECT_DIR"
  docker compose -f "$COMPOSE_FILE" down >> "$LOG" 2>&1

  log "Rebuilding image for $PROJECT_DIR"
  docker compose -f "$COMPOSE_FILE" build >> "$LOG" 2>&1

  log "Redeploying $PROJECT_DIR"
  docker compose -f "$COMPOSE_FILE" up -d >> "$LOG" 2>&1

  log "Done: $PROJECT_DIR"
}

# ── Discover and process every project under /opt/appdata ────────────────────
for PROJECT_DIR in /opt/appdata/*/; do
  PROJECT_DIR="${PROJECT_DIR%/}"  # strip trailing slash
  COMPOSE_FILE="$PROJECT_DIR/compose.yaml"

  if [ ! -f "$COMPOSE_FILE" ]; then
    log "SKIP: No compose file found at $COMPOSE_FILE"
    continue
  fi

  if grep -qE '^\s*build:' "$COMPOSE_FILE"; then
    update_build_project "$PROJECT_DIR"
  else
    update_project "$PROJECT_DIR"
  fi
done

# ── Prune ALL unused images (-a, not just dangling) and the build cache ───────
# Images not used by a running container are removed; anything needed again is
# pulled or rebuilt on the next run.
log "Pruning unused images..."
docker image prune -af >> "$LOG" 2>&1

log "Pruning build cache..."
docker builder prune -af >> "$LOG" 2>&1

log "All projects processed."

/opt/scripts/docker-update-notify.sh "$START_LINE"
