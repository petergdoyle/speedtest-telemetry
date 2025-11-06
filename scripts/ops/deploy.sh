#!/usr/bin/env bash
set -euo pipefail

REPO="$HOME/speedtest-logs"
SRC="$REPO/systemd/user"
DST="$HOME/.config/systemd/user"

mkdir -p "$DST"

for u in speedtest-logger.service speedtest-logger.timer speedtest-dashboard.service; do
  ln -sf "$SRC/$u" "$DST/$u"
done

systemctl --user daemon-reload
systemctl --user enable --now speedtest-logger.timer
systemctl --user enable --now speedtest-dashboard.service

echo "---- Status ----"
systemctl --user list-timers | grep speedtest-logger || true
systemctl --user status speedtest-dashboard.service --no-pager -l || true
