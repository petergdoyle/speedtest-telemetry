# 🛠️ systemd units (user) for Speedtest Telemetry

This folder contains **user-level** systemd units that run speedtest logging on a schedule and the dashboard as a service.

## Files

- `user/speedtest-logger.service`  
  Runs the logger **once** (Type=oneshot). It calls:  
  `~/speedtest-logs/scripts/speedtest-log.sh`

- `user/speedtest-logger.timer`  
  Schedules the logger (default: **every 15 minutes**) with `Persistent=true` so missed runs execute after reboot.

- `user/speedtest-dashboard.service`  
  Starts the Dash web app on port `DASH_PORT` (default **8050**), using the top-level venv and `dashboard/speedtest-dashboard-env-run.sh`.

## Deploy / Enable

Use the helper script to link units into your user systemd dir and enable them:

```bash
~/speedtest-logs/scripts/ops/deploy.sh
