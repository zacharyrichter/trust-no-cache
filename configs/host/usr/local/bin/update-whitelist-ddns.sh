#!/bin/bash
# =============================================================================
# nftables whitelist updater: Cloudflare API edition
# Secrets live in /etc/nftables-ddns.env (root:root, mode 600), not in this file.
# =============================================================================

# --- Configuration -----------------------------------------------------------
ENV_FILE="/etc/nftables-ddns.env"
if [[ ! -r "$ENV_FILE" ]]; then
    echo "ERROR: cannot read $ENV_FILE" >&2
    exit 1
fi
source "$ENV_FILE"   # sets CF_API_TOKEN, CF_ZONE_ID, CF_RECORD_ID, CF_RECORD_NAME

NFT_TABLE="inet filter"
NFT_SET="whitelist"

STATE_DIR="/var/lib/nftables-ddns"
STATE_FILE="${STATE_DIR}/ip"
LOG_FILE="/run/nftables-ddns.log"
TRAEFIK_CONFIG="/opt/appdata/traefik/config/fileConfig.yml"
# -----------------------------------------------------------------------------

mkdir -p "$STATE_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

HTTP_CODE=$(curl -s --max-time 20 -o /run/cf_response.json -w "%{http_code}" \
    -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${CF_RECORD_ID}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json")

if [[ "$HTTP_CODE" != "200" ]]; then
    log "ERROR: Cloudflare API returned HTTP $HTTP_CODE — aborting"
    cat /run/cf_response.json >> "$LOG_FILE" 2>/dev/null
    exit 1
fi

CF_SUCCESS=$(python3 -c "import json; d=json.load(open('/run/cf_response.json')); print(d.get('success', False))")
if [[ "$CF_SUCCESS" != "True" ]]; then
    log "ERROR: Cloudflare API reported failure:"
    cat /run/cf_response.json >> "$LOG_FILE"
    exit 1
fi

NEW_IP=$(python3 -c "import json; d=json.load(open('/run/cf_response.json')); print(d['result']['content'])")

if [[ ! "$NEW_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log "ERROR: Parsed IP looks invalid: '$NEW_IP' — aborting"
    exit 1
fi

OLD_IP=$(cat "$STATE_FILE" 2>/dev/null)

# Check whether the current IP is actually present in the nftables set
CURRENT_IN_SET=$(nft list set "$NFT_TABLE" "$NFT_SET" 2>/dev/null | grep -c -F "$NEW_IP")

# Exit only if the state file matches AND the nftables set already contains the IP
if [[ "$NEW_IP" == "$OLD_IP" && "$CURRENT_IN_SET" -gt 0 ]]; then
    exit 0
fi

if [[ "$NEW_IP" != "$OLD_IP" ]]; then
    log "IP change detected for $CF_RECORD_NAME: ${OLD_IP:-'(none)'} → $NEW_IP"
else
    log "IP unchanged; ensuring $NEW_IP is present in set '$NFT_SET'"
fi

if [[ -n "$OLD_IP" && "$OLD_IP" != "$NEW_IP" ]]; then
    if nft delete element "$NFT_TABLE" "$NFT_SET" "{ $OLD_IP }" 2>/dev/null; then
        log "Removed old IP $OLD_IP from set '$NFT_SET'"
    else
        log "WARNING: Could not remove old IP $OLD_IP (may not exist in set — continuing)"
    fi
fi

if nft add element "$NFT_TABLE" "$NFT_SET" "{ $NEW_IP }" 2>/dev/null; then
    log "Added new IP $NEW_IP to set '$NFT_SET'"
    echo "$NEW_IP" > "$STATE_FILE"
else
    log "ERROR: Failed to add $NEW_IP to nftables — manual intervention needed"
    exit 1
fi

# --- Update Traefik ipAllowList ---------------------------------------------
if [[ "$NEW_IP" != "$OLD_IP" ]]; then
    if [[ -n "$OLD_IP" ]]; then
        sed -i "s|${OLD_IP}/32|${NEW_IP}/32|g" "$TRAEFIK_CONFIG"
        log "Updated Traefik ipAllowList: ${OLD_IP}/32 → ${NEW_IP}/32"
    else
        if ! grep -qF "${NEW_IP}/32" "$TRAEFIK_CONFIG"; then
            sed -i "/ipAllowList:/,/sourceRange:/{/sourceRange:/a\\          - \"${NEW_IP}/32\"}" "$TRAEFIK_CONFIG"
            log "Added ${NEW_IP}/32 to Traefik ipAllowList"
        fi
    fi
fi

log "Whitelist update complete."
