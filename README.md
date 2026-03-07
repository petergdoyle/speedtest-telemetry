# Speedtest Telemetry Logger & Dashboard

Logs Ookla Speedtest results + ICMP (gateway, 1.1.1.1, 8.8.8.8), DNS query time, and HTTP reachability to CSV. Includes a built-in Streamlit dashboard for real-time visualization.

Autodiscovers nearby servers (`speedtest -L`) and falls back to a static list. Uses a robust containerized `systemd` deployment architecture.

## Architecture
The entire stack runs inside a lightweight, standalone Ubuntu Docker container using `systemd` internally.
- **Log Service**: A systemd timer (`speedtest-logger.timer`) triggers the telemetry script every 15 minutes.
- **Dashboard Service**: A long-running systemd service (`speedtest-dashboard.service`) serves the Streamlit UI.
- **Persistence**: All data is written to a Docker named-volume (`speedtest-data`) mapped securely to `/var/lib/speedtest-telemetry`.

## Prerequisites
- [Docker Engine or Docker Desktop](https://docs.docker.com/get-docker/) deployed on your host machine.
- `make` installed.

Run the following command to verify your system is ready:
```bash
make setup
```

## Quick Start
1. Build the Docker image:
```bash
make build
```
2. Start the telemetry logger and dashboard container in the background:
```bash
make run
```
3. View the live web dashboard at: [http://localhost:8501](http://localhost:8501)

## Makefile Commands

The project uses a `Makefile` to simplify deployment and management.

| Command | Description |
|---|---|
| `make help` | Show all available commands |
| `make env` / `make setup` | Setup local environment and verify Docker prerequisites |
| `make build` | Compile the container image |
| `make run` | Start the local container in detached mode |
| `make stop` | Stop the container safely |
| `make test` | Force trigger a manual speedtest run immediately |
| `make logger-logs` | Follow the tailing logs for the telemetry script |
| `make dashboard-logs` | Follow the tailing logs for the Streamlit dashboard |
| `make shell` | Spawn an interactive `/bin/bash` terminal into the container |
| `make clean` | **Destructive**: Remove the container and the associated CSV data volume |

## CSV Format
Data is stored internally in `/var/lib/speedtest-telemetry/speedtest.csv`.

**Header:**
```csv
timestamp,download_mbps,upload_mbps,ping_ms,jitter_ms,packet_loss,server_name,server_id,isp,gw_ping_ms,gw_loss_pct,cf_ping_ms,cf_loss_pct,g_ping_ms,g_loss_pct,dns_ms,http_ms,status,error
```

**Sample Row:**
```csv
2025-11-05 04:13:51,70.993,29.246,98.846,20.615,2.0067,T-Mobile Fiber | Intrepid,56839,T-Mobile USA,6.2,0,18.4,0,21.3,0,16,102,ok,
```
