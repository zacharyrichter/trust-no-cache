#!/bin/bash
# /opt/scripts/integrity-check.sh
# Lightweight drift detection for sensitive system paths

PATHS="/etc /usr/bin /usr/sbin /boot"
MANIFEST_DIR="/var/lib/simple-integrity"
NEW="$MANIFEST_DIR/manifest.new"
OLD="$MANIFEST_DIR/manifest"

# NTFY_URL and NTFY_TOKEN come from the shared env file
. /etc/ntfy-sendmail.env || { echo "integrity-check: cannot read /etc/ntfy-sendmail.env" >&2; exit 1; }

# Body on stdin, $1 = title. ntfy rejects bodies over 4096 bytes, so cap at 3500.
notify() {
    head -c 3500 | curl -sf --max-time 20 -o /dev/null \
      -H "Authorization: Bearer ${NTFY_TOKEN}" \
      -H "Title: $1" \
      --data-binary @- "${NTFY_URL}"
}

mkdir -p "$MANIFEST_DIR"
find $PATHS -type f -exec sha256sum {} \; 2>/dev/null | sort > "$NEW"

if [ -f "$OLD" ]; then
    DIFF=$(diff "$OLD" "$NEW")
    if [ -n "$DIFF" ]; then
        LINES=$(echo "$DIFF" | wc -l)
        if ! echo "$DIFF" | grep '^[<>]' | sed -E 's/^([<>]) [0-9a-f]{64}  /\1 /' | notify "Integrity check: $LINES changed lines"; then
            echo "integrity-check: ntfy send failed; keeping the old baseline" >&2
            exit 1
        fi
    fi
else
    if ! echo "Initial baseline created" | notify "Integrity check initialized"; then
        echo "integrity-check: ntfy send failed" >&2
        exit 1
    fi
fi

mv "$NEW" "$OLD"
