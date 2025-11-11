# 📡 Unattended Execution and Systemd Integration

## 🔹 Project Layout

```
speedtest-logs/systemd/
├── README.md
└── user
    ├── speedtest-dashboard.service
    ├── speedtest-logger.service
    └── speedtest-logger.timer
```

These files support unattended, self-running telemetry and dashboard services on Linux systems.

---

# 📠 1. Options for Unattended Execution

## A) Crontab

**Pros:**
- Simple and widely supported.
- Easy syntax (`crontab -e`).

**Cons:**
- No native logging (must redirect manually).
- No dependency awareness (e.g. network-online.target).
- Missed jobs during sleep are skipped.

**Best for:** Minimal systems or quick tests.

---

## B) Systemd (Recommended)

**Pros:**
- Built-in logging via `journalctl`.
- Handles dependencies (network, mounts, etc.).
- Flexible scheduling (`OnUnitActiveSec`, `OnCalendar`).
- Resilient and persistent across reboots.

**Cons:**
- Requires a couple of small unit files.

**Best for:** Long-running services and reliable telemetry.

---

# 🔹 2. File Locations & Types

## A) User Services (Preferred)
- Installed under:
  ```bash
  ~/.config/systemd/user/
  ```
- Controlled with:
  ```bash
  systemctl --user ...
  ```

**Advantages:**
- No root needed.
- Runs independently of desktop sessions if you enable lingering:
  ```bash
  loginctl enable-linger $USER
  ```

## B) System Services
- Installed under `/etc/systemd/system/`.
- Controlled with `sudo systemctl ...`.

Use this only for always-on headless servers.

---

# 🔹 3. Installation Guide

### Step 1: Copy Units into Place
```bash
mkdir -p ~/.config/systemd/user
cp -v ~/speedtest-logs/systemd/user/*.service ~/.config/systemd/user/
cp -v ~/speedtest-logs/systemd/user/*.timer ~/.config/systemd/user/
```

### Step 2: Reload Systemd Daemon
```bash
systemctl --user daemon-reload
```

### Step 3: Enable and Start the Logger Timer
```bash
systemctl --user enable speedtest-logger.timer
systemctl --user start  speedtest-logger.timer
```

### Step 4: (Optional) Enable Dashboard Service
```bash
systemctl --user enable speedtest-dashboard.service
systemctl --user start  speedtest-dashboard.service
```

---

# 🔹 4. Managing the Logger Timer

### Check Timers
```bash
systemctl --user list-timers
```

### View Status
```bash
systemctl --user status speedtest-logger.timer
```

### Run Immediately
```bash
systemctl --user start speedtest-logger.service
```

### Stop or Disable
```bash
systemctl --user stop    speedtest-logger.timer
systemctl --user disable speedtest-logger.timer
```

### Logs
```bash
journalctl --user -u speedtest-logger.service -n 100 --no-pager
```

### Dashboard Management
```bash
systemctl --user status  speedtest-dashboard.service
systemctl --user restart speedtest-dashboard.service
journalctl --user -u speedtest-dashboard.service -f
```

---

# 🔹 5. Timer Examples

## Option A: Interval Timer (Every 15 Minutes)
```ini
[Timer]
OnUnitActiveSec=15min
AccuracySec=1min
Persistent=true
```

Runs every 15 minutes after the last successful run.

## Option B: Wall-Clock Timer (Cron Style)
```ini
[Timer]
OnCalendar=*:0/15
AccuracySec=1min
Persistent=true
```

Runs on exact 0, 15, 30, 45-minute marks of each hour.

---

# 🔹 6. Example Service File

```ini
[Unit]
Description=Speedtest Telemetry Logger (One Shot)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=%h/speedtest-logs
EnvironmentFile=%h/speedtest-logs/config.env
ExecStart=%h/speedtest-logs/scripts/speedtest-log.sh

[Install]
WantedBy=default.target
```

Ensure the script is executable:
```bash
chmod +x ~/speedtest-logs/scripts/speedtest-log.sh
```

---

# 🔹 7. Troubleshooting

### Timer not running?
```bash
systemctl --user list-timers | grep speedtest
loginctl enable-linger $USER
systemctl --user daemon-reload
```

### Service fails?
```bash
journalctl --user -u speedtest-logger.service -n 100 --no-pager
```

### CSV not updating?
Check file paths and permissions in `config.env`.

### Dashboard not reachable?
```bash
sudo ufw allow 8050/tcp
sudo ufw status
```

### Change schedule?
Edit timer, then:
```bash
systemctl --user daemon-reload
systemctl --user restart speedtest-logger.timer
```

---

# 🔹 8. Quick Command Reference

```bash
systemctl --user daemon-reload
systemctl --user enable speedtest-logger.timer
systemctl --user start  speedtest-logger.timer
systemctl --user start  speedtest-logger.service
systemctl --user list-timers
journalctl --user -u speedtest-logger.service -n 100 --no-pager
systemctl --user enable speedtest-dashboard.service
systemctl --user restart speedtest-dashboard.service
journalctl --user -u speedtest-dashboard.service -f
```

---

# 🔹 9. Optional: Always-On Keep-Awake Service

```bash
sudo tee /etc/systemd/system/keepawake.service >/dev/null <<'EOF'
[Unit]
Description=Prevent system sleep indefinitely
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/systemd-inhibit --mode=block --what=sleep --why="Permanent keep-awake for telemetry" sleep infinity
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now keepawake.service
```

