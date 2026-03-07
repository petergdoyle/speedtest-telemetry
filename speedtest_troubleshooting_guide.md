# Speedtest Telemetry Troubleshooting Guide (Docker Edition)

This guide provides a systematic process for verifying and repairing the `speedtest-telemetry` stack running inside Docker.

---

## 1) Check Container Status
The first step is ensuring the container is actually running and healthy.

```bash
# Check if the container is running
docker ps --filter "name=speedtest-telemetry"

# Check the last 100 lines of general container output
make logs
```

- **If the container is missing**: Run `make run`.
- **If the container is "Exited"**: Check `make logs` for initialization errors.

---

## 2) Verify Systemd Services
Inside the container, we use systemd to manage the schedule. 

```bash
# Check the status of the timer and the dashboard service
docker exec speedtest-telemetry systemctl status speedtest-logger.timer speedtest-dashboard.service
```

- **`speedtest-logger.timer`**: Must be `active (waiting)`. This triggers the runs.
- **`speedtest-dashboard.service`**: Must be `active (running)`. This serves the UI.

---

## 3) Inspect Service Logs
If a specific service is failing, tail its dedicated journal logs:

```bash
# View logs for the telemetry logger script
make logger-logs

# View logs for the Streamlit dashboard
make dashboard-logs
```

---

## 4) Manual Data Verification
Verify that the CSV is actually being written to the persistent volume.

```bash
# Check the CSV header and last 5 rows
docker exec speedtest-telemetry tail -n 5 /var/lib/speedtest-telemetry/speedtest.csv

# Check for script-level errors
docker exec speedtest-telemetry cat /var/lib/speedtest-telemetry/errors.log
```

---

## 5) Force a Manual Test Run
If you don't want to wait for the 15-minute timer, trigger a run immediately:

```bash
make test
```
Then check `make logger-logs` to see it execute in real-time.

---

## 6) Common Docker/Proxmox Issues

| Issue | Symptom | Fix |
|--------|----------|------|
| **Cgroup v2 Error** | Container fails to start systemd | Ensure the host has Cgroup v2 enabled and `privileged: true` is in `docker-compose.yml`. |
| **LXC Nesting** | Systemd fails inside LXC | (Proxmox only) Enable **Nesting** and **FUSE** in LXC Options. |
| **Port Conflict** | `make run` fails on port 8501 | Change `8501:8501` in `docker-compose.yml` to another port (e.g., `9000:8501`). |
| **Permission Denied** | Logs won't write to `/var/lib/...` | The container runs as root by default. Ensure the host path for the volume is accessible. |
| **Speedtest CLI Crash** | `std::logic_error` in logs | Ensure `Environment=HOME=/root` is set in the systemd service file (it should be by default in this repo). |

---

## 7) Interactive Debugging
If all else fails, "ssh" into the container to run commands manually:

```bash
make shell
# Inside the container:
/app/scripts/speedtest-log.sh
```

---

## Summary
1. Use `make help` to see all diagnostic commands.
2. Check `make logger-logs` for speedtest failures.
3. Check `make dashboard-logs` for Streamlit/UI failures.
4. Ensure your host supports `systemd` inside Docker (Privileged mode).

