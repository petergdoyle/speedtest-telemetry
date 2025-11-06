# Speedtest Telemetry Logger

Logs Ookla Speedtest results + ICMP (gateway, 1.1.1.1, 8.8.8.8), DNS query time, and HTTP reachability to CSV (and optionally SQLite).  
Autodiscovers nearby servers (`speedtest -L`) and falls back to a static list. Cron-safe (flock). Systemd-ready. Docker-ready.

## Repo Layout
speedtest-logs/
├── scripts/
│ └── speedtest-log.sh
├── data/
│ ├── speedtest.csv
│ ├── raw/
│ ├── errors.log
│ └── .speedtest.lock
├── .gitignore
└── README.md


## Prereqs
- Ubuntu 24.x
- Ookla CLI installed at `/usr/local/bin/speedtest`
- `jq`, `dnsutils`, `curl`

```bash
sudo apt update
sudo apt install -y jq dnsutils curl
```

## Run once
./scripts/speedtest-log.sh
tail -2 data/speedtest.csv

## CSV Header
timestamp,download_mbps,upload_mbps,ping_ms,jitter_ms,packet_loss,server_name,server_id,isp,gw_ping_ms,gw_loss_pct,cf_ping_ms,cf_loss_pct,g_ping_ms,g_loss_pct,dns_ms,http_ms,status,error

## Sample Row
2025-11-05 04:13:51,70.993,29.246,98.846,20.615,2.0067,T-Mobile Fiber | Intrepid,56839,T-Mobile USA,6.2,0,18.4,0,21.3,0,16,102,ok,

