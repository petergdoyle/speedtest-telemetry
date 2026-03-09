#!/usr/bin/env bash
echo "=== SYSTEMD INIT CHECK ==="
ps aux | grep /sbin/init

echo -e "\n=== SERVICE STATUS ==="
systemctl status speedtest-logger.timer speedtest-logger.service speedtest-dashboard.service --no-pager

echo -e "\n=== TIMER LIST ==="
systemctl list-timers --no-pager

echo -e "\n=== RECENT LOGGER LOGS ==="
journalctl -u speedtest-logger.service -n 50 --no-pager

echo -e "\n=== RECENT DASHBOARD LOGS ==="
journalctl -u speedtest-dashboard.service -n 50 --no-pager

echo -e "\n=== ERROR LOG FILE ==="
cat /var/lib/speedtest-telemetry/errors.log 2>/dev/null || echo "No errors.log found."

echo -e "\n=== DATA DIRECTORY CHECK ==="
ls -lh /var/lib/speedtest-telemetry/
tail -n 5 /var/lib/speedtest-telemetry/speedtest.csv 2>/dev/null || echo "No speedtest.csv found."
