#!/usr/bin/env bash
# Speedtest Telemetry Archiving Script
# -----------------------------------
# Rotates the main speedtest.csv and cleans up old raw JSON files.
# Default retention: 90 days.

set -euo pipefail

BASE_DIR="${SPEEDTEST_DATA:-/var/lib/speedtest-telemetry}"
CSV="$BASE_DIR/speedtest.csv"
RAW_DIR="$BASE_DIR/raw"
RETENTION_DAYS="${SPEEDTEST_RETENTION_DAYS:-90}"
DATE_TAG=$(date +%Y-%m-%d)
ARCHIVE_NAME="$BASE_DIR/speedtest_archive_${DATE_TAG}.csv"

echo "[$(date)] Starting archive process (Retention: $RETENTION_DAYS days)..."

# 1. Archive the main CSV if it has data older than retention
if [ -f "$CSV" ]; then
    LINES=$(wc -l < "$CSV")
    if [ "$LINES" -gt 1 ]; then
        # Get the timestamp of the first data row (line 2)
        FIRST_TS=$(sed -n '2p' "$CSV" | cut -d',' -f1)
        if [ -n "$FIRST_TS" ]; then
            FIRST_EPOCH=$(date -d "$FIRST_TS" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$FIRST_TS" +%s 2>/dev/null || echo 0)
            NOW_EPOCH=$(date +%s)
            AGE_DAYS=$(( (NOW_EPOCH - FIRST_EPOCH) / 86400 ))

            if [ "$AGE_DAYS" -ge "$RETENTION_DAYS" ]; then
                echo "[$(date)] Data is $AGE_DAYS days old. Archiving $CSV to $ARCHIVE_NAME..."
                cp "$CSV" "$ARCHIVE_NAME"
                echo "timestamp,download_mbps,upload_mbps,ping_ms,jitter_ms,packet_loss,server_name,server_id,isp,gw_ping_ms,gw_loss_pct,cf_ping_ms,cf_loss_pct,g_ping_ms,g_loss_pct,dns_ms,http_ms,wifi_iface,wifi_ssid,wifi_band,status,error" > "$CSV"
                echo "[$(date)] CSV rotated."
            else
                echo "[$(date)] Oldest data is $AGE_DAYS days old. Skipping rotation (Threshold: $RETENTION_DAYS)."
            fi
        fi
    else
        echo "[$(date)] CSV is empty (only header), skipping rotation."
    fi
fi

# 2. Cleanup raw JSON files older than retention period
if [ -d "$RAW_DIR" ]; then
    echo "[$(date)] Cleaning up raw JSON files older than $RETENTION_DAYS days..."
    find "$RAW_DIR" -name "*.json" -type f -mtime +"$RETENTION_DAYS" -delete
    echo "[$(date)] Cleanup complete."
fi

# 3. Cleanup older archives (optional: keep only last few archives?)
# For now, we just let them accumulate as requested by "archive mechanism".

echo "[$(date)] Archiving process finished."
