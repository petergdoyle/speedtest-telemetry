# Speedtest Telemetry Troubleshooting Guide

This guide provides a systematic process for verifying and repairing the `speedtest-telemetry` app if it stops logging data. Follow these steps in order.

---

## 0) Set Variables (once per shell)
```bash
# CHANGE this to your project root
PROJ=~/speedtest-telemetry
cd "$PROJ"
```

---

## 1) Verify that new data is missing
```bash
ls -lh data/speedtest.csv
tail -n 5 data/speedtest.csv
stat -c "mtime: %y" data/speedtest.csv
```
- If `mtime` is older than 24–48 hours → logging has stopped.

---

## 2) Check for error logs
```bash
[ -f data/errors.log ] && tail -n 50 data/errors.log || echo "No errors.log"
```

---

## 3) Look for stale lock files
```bash
if [ -f data/.speedtest.lock ]; then
  echo "Lock age:"; stat -c "%y" data/.speedtest.lock
  # if older than ~1hr, it's likely stale:
  find data/.speedtest.lock -mmin +60 -print -exec rm -v {} \;
else
  echo "No lock present."
fi
```

---

## 4) Verify Ookla Speedtest CLI availability
```bash
command -v speedtest || echo "speedtest CLI not on PATH"
speedtest --version || echo "Speedtest exists but failed to run"
```
If missing, reinstall:
```bash
curl -s https://packagecloud.io/install/repositories/ookla/speedtest/script.deb.sh | sudo bash
sudo apt-get install -y speedtest
```

---

## 5) Run the capture script manually
```bash
chmod +x scripts/run_speedtest.sh 2>/dev/null || true
./scripts/run_speedtest.sh && tail -n 3 data/speedtest.csv
```
- If data appends to CSV → scheduling issue (cron/systemd)
- If fails → check `data/errors.log`

---

## 6) Verify environment
Ensure the following:
- `data/` exists and is writable
- `speedtest` is on PATH
- Python/venv are used only for dashboard/notebook layers

Quick check:
```bash
mkdir -p data/raw
touch data/smoke.txt && rm data/smoke.txt
```

---

## 7) Cron Configuration
### Inspect crontab
```bash
crontab -l | sed -n '1,120p'
sudo crontab -l | sed -n '1,120p' || true
```

### Recommended user crontab
```bash
MAILTO=""
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Every 15 minutes with lock
*/15 * * * * cd $HOME/speedtest-telemetry && ./scripts/run_speedtest.sh >> data/errors.log 2>&1
```

---

## 8) Systemd Timer Alternative
Check status:
```bash
systemctl --user status speedtest-telemetry.timer speedtest-telemetry.service
journalctl --user -u speedtest-telemetry.service -n 100 --no-pager
```

### Service file (~/.config/systemd/user/speedtest-telemetry.service)
```
[Unit]
Description=Run speedtest telemetry capture

[Service]
Type=oneshot
WorkingDirectory=%h/speedtest-telemetry
ExecStart=%h/speedtest-telemetry/scripts/run_speedtest.sh
```

### Timer file (~/.config/systemd/user/speedtest-telemetry.timer)
```
[Unit]
Description=Run speedtest telemetry every 15 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Unit=speedtest-telemetry.service

[Install]
WantedBy=timers.target
```

Activate:
```bash
systemctl --user daemon-reload
systemctl --user enable --now speedtest-telemetry.timer
systemctl --user list-timers | grep speedtest-telemetry
```

---

## 9) Health Check Script
Save as `scripts/health_check.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== CSV ==="
[ -f data/speedtest.csv ] && { wc -l data/speedtest.csv; stat -c "mtime: %y" data/speedtest.csv; } || echo "missing"

echo "=== Lock ==="
if [ -f data/.speedtest.lock ]; then
  stat -c "lock mtime: %y" data/.speedtest.lock
  find data/.speedtest.lock -mmin +60 -print -exec rm -v {} \;
else
  echo "no lock"
fi

echo "=== Errors tail ==="
[ -f data/errors.log ] && tail -n 30 data/errors.log || echo "no errors.log"

echo "=== speedtest CLI ==="
command -v speedtest && speedtest --version || echo "speedtest not available"

echo "=== Cron user ==="
crontab -l || echo "no user crontab"

echo "=== Systemd user timer ==="
systemctl --user list-timers | (grep speedtest-telemetry || true)
```
Run:
```bash
chmod +x scripts/health_check.sh
./scripts/health_check.sh
```

---

## 10) Common Issues & Fixes
| Issue | Symptom | Fix |
|--------|----------|------|
| **Stale lock** | `.speedtest.lock` exists for hours | Delete it using `find ... -exec rm` |
| **Cron PATH issue** | `speedtest` not found | Add PATH in crontab |
| **Permissions** | Files owned by root | `sudo chown -R "$USER":"$USER" "$PROJ"` |
| **Device sleeps** | No runs during sleep | `sudo systemctl mask sleep.target suspend.target` |
| **Disk full** | `df -h` near 100% | Rotate or delete old logs |
| **Binary moved** | CLI path changed | Reinstall or export PATH again |

---

## 11) Test the CLI directly
```bash
speedtest --accept-license --accept-gdpr -f json > /tmp/st.json && jq '.type, .ping.latency, .download.bandwidth, .upload.bandwidth' /tmp/st.json
```
- Fails → network or CLI issue
- Works → script or scheduling issue

---

## Summary
Run the health check first. If issues persist:
1. Check for stale lock
2. Verify cron/systemd timers
3. Validate CLI and permissions

If the manual run works but automation doesn’t, the root cause is always **PATH**, **permissions**, or **scheduler config**.

