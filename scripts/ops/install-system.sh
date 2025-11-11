#!/usr/bin/env bash
set -euo pipefail

SRC="${1:-$HOME/speedtest-telemetry}"
DEST_CODE="/opt/speedtest-telemetry"
DEST_DATA="/var/lib/speedtest-telemetry"
DEST_LOG="/var/log/speedtest-telemetry"
UNIT_DIR="/etc/systemd/system"

echo "==> Preflight"
command -v rsync >/dev/null || { echo "Installing rsync"; sudo apt-get update -y && sudo apt-get install -y rsync; }

echo "==> Create system user 'speedtest' (no login)"
if ! id -u speedtest >/dev/null 2>&1; then
  sudo useradd --system --home "$DEST_CODE" --shell /usr/sbin/nologin speedtest
fi

echo "==> Sync project to $DEST_CODE"
sudo mkdir -p "$DEST_CODE"
sudo rsync -a --delete --exclude=".git" --exclude=".github" --exclude="__pycache__" "$SRC"/ "$DEST_CODE"/
sudo chmod +x "$DEST_CODE/scripts/speedtest-log.sh"

echo "==> Prepare data and log dirs"
sudo mkdir -p "$DEST_DATA/raw"
sudo mkdir -p "$DEST_LOG"
# migrate existing data if present
if [ -d "$SRC/data" ]; then
  echo "==> Migrating existing data from $SRC/data -> $DEST_DATA"
  sudo rsync -a "$SRC/data/" "$DEST_DATA/"
fi

echo "==> Ownerships"
sudo chown -R speedtest:speedtest "$DEST_CODE" "$DEST_DATA" "$DEST_LOG"

echo "==> Wire symlinks so the existing script keeps working"
# If the script writes into ./data relative to code dir, make data a symlink
if [ -e "$DEST_CODE/data" ] || [ -L "$DEST_CODE/data" ]; then
  sudo rm -rf "$DEST_CODE/data"
fi
sudo ln -s "$DEST_DATA" "$DEST_CODE/data"

# errors.log is expected under data/errors.log; place the canonical file in /var/log and link it
if [ -e "$DEST_DATA/errors.log" ] || [ -L "$DEST_DATA/errors.log" ]; then
  sudo rm -f "$DEST_DATA/errors.log"
fi
sudo touch "$DEST_LOG/errors.log"
sudo chown speedtest:speedtest "$DEST_LOG/errors.log"
sudo ln -s "$DEST_LOG/errors.log" "$DEST_DATA/errors.log"

echo "==> Create systemd units"
sudo tee "$UNIT_DIR/speedtest-logger.service" >/dev/null <<'EOF'
[Unit]
Description=Speedtest Telemetry Logger (runs once)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=speedtest
Group=speedtest
WorkingDirectory=/opt/speedtest-telemetry
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/opt/speedtest-telemetry/scripts/speedtest-log.sh
TimeoutStartSec=30min
# Hardening (optional):
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ProtectControlGroups=true
ProtectKernelTunables=true
ProtectKernelModules=true
LockPersonality=true
RestrictRealtime=true
EOF

sudo tee "$UNIT_DIR/speedtest-logger.timer" >/dev/null <<'EOF'
[Unit]
Description=Run Speedtest Telemetry Logger every 15 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Unit=speedtest-logger.service
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF

echo "==> Enable timer"
sudo systemctl daemon-reload
sudo systemctl enable --now speedtest-logger.timer

echo "==> Done."
echo "Check: sudo systemctl status speedtest-logger.timer --no-pager"
echo "Run once now: sudo systemctl start speedtest-logger.service"
echo "Tail logs: sudo journalctl -u speedtest-logger.service -n 100 --no-pager"