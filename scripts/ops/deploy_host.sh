#!/usr/bin/env bash
# Host-based deployment for speedtest-telemetry (systemd + system user)
# Target: Ubuntu-like systems

set -euo pipefail

log()  { echo "[$(date -Iseconds)] $*"; }
ok()   { log "✅ $*"; }
warn() { log "⚠️  $*"; }
err()  { log "❌ $*" >&2; }

# Require root (run with sudo)
if [[ "${EUID}" -ne 0 ]]; then
  err "This script must be run as root. Try: sudo bash $0"
  exit 1
fi

# Resolve repo root (script is in scripts/ops/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

APP_USER="speedtest"
APP_GROUP="speedtest"
APP_ROOT="/opt/speedtest-telemetry"
DATA_DIR="/var/lib/speedtest-telemetry"
LOG_FILE="/var/log/speedtest-diag.log"
VENV_DIR="${APP_ROOT}/.venv"
REQUIREMENTS_FILE="${APP_ROOT}/requirements.txt"
CONFIG_FILE="${APP_ROOT}/config.env"

log "Starting host-based deployment from repo root: ${REPO_ROOT}"

# 1) Install prerequisites
log "Installing prerequisites (python3, venv, pip, curl)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3 python3-venv python3-pip curl

ok "Base packages installed."

# 2) Create system user if needed
if id -u "${APP_USER}" >/dev/null 2>&1; then
  ok "System user '${APP_USER}' already exists."
else
  log "Creating system user '${APP_USER}'..."
  useradd -r -s /usr/sbin/nologin "${APP_USER}"
  ok "System user '${APP_USER}' created."
fi

# 3) Copy repo into /opt
log "Syncing project into ${APP_ROOT}..."
mkdir -p "${APP_ROOT}"
rsync -a --delete "${REPO_ROOT}/" "${APP_ROOT}/"
ok "Project synced to ${APP_ROOT}."

# 4) Create venv and install requirements
log "Setting up virtual environment at ${VENV_DIR}..."
if [[ ! -d "${VENV_DIR}" ]]; then
  python3 -m venv "${VENV_DIR}"
  ok "Virtual environment created."
else
  ok "Virtual environment already exists."
fi

log "Installing Python dependencies..."
"${VENV_DIR}/bin/pip" install --upgrade pip
if [[ -f "${REQUIREMENTS_FILE}" ]]; then
  "${VENV_DIR}/bin/pip" install -r "${REQUIREMENTS_FILE}"
  ok "Python dependencies installed."
else
  warn "No requirements.txt found at ${REQUIREMENTS_FILE}."
fi

# 5) Data + log directories
log "Ensuring data and log paths exist..."
mkdir -p "${DATA_DIR}/raw"
touch "${DATA_DIR}/speedtest.csv"
touch "${LOG_FILE}"
ok "Data dir: ${DATA_DIR}, Log file: ${LOG_FILE}"

# 6) Ownership
log "Setting ownership to ${APP_USER}:${APP_GROUP}..."
chown -R "${APP_USER}:${APP_GROUP}" "${APP_ROOT}"
chown -R "${APP_USER}:${APP_GROUP}" "${DATA_DIR}"
chown "${APP_USER}:${APP_GROUP}" "${LOG_FILE}"
ok "Ownership updated."

# 7) Ensure SPEEDTEST_IFACE in config.env (if not present)
log "Checking network interface for SPEEDTEST_IFACE..."
DEFAULT_IFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' || true)"

if [[ -n "${DEFAULT_IFACE}" ]]; then
  log "Detected default interface: ${DEFAULT_IFACE}"
else
  warn "Could not auto-detect default interface; SPEEDTEST_IFACE will need to be set manually."
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
  log "Creating ${CONFIG_FILE}..."
  cat > "${CONFIG_FILE}" <<EOF
# speedtest-telemetry configuration (host deployment)

SPEEDTEST_CSV=${DATA_DIR}/speedtest.csv
SPEEDTEST_RAW=${DATA_DIR}/raw
SPEEDTEST_REFRESH=300
EOF
  if [[ -n "${DEFAULT_IFACE}" ]]; then
    echo "SPEEDTEST_IFACE=${DEFAULT_IFACE}" >> "${CONFIG_FILE}"
  fi
  ok "Created ${CONFIG_FILE}."
else
  if ! grep -q '^SPEEDTEST_CSV=' "${CONFIG_FILE}"; then
    echo "SPEEDTEST_CSV=${DATA_DIR}/speedtest.csv" >> "${CONFIG_FILE}"
  fi
  if ! grep -q '^SPEEDTEST_RAW=' "${CONFIG_FILE}"; then
    echo "SPEEDTEST_RAW=${DATA_DIR}/raw" >> "${CONFIG_FILE}"
  fi
  if ! grep -q '^SPEEDTEST_REFRESH=' "${CONFIG_FILE}"; then
    echo "SPEEDTEST_REFRESH=300" >> "${CONFIG_FILE}"
  fi
  if [[ -n "${DEFAULT_IFACE}" ]] && ! grep -q '^SPEEDTEST_IFACE=' "${CONFIG_FILE}"; then
    echo "SPEEDTEST_IFACE=${DEFAULT_IFACE}" >> "${CONFIG_FILE}"
  fi
  ok "Updated ${CONFIG_FILE} with missing defaults (if any)."
fi

chown "${APP_USER}:${APP_GROUP}" "${CONFIG_FILE}"

# 8) Systemd service + timer
log "Installing systemd units..."

cat > /etc/systemd/system/speedtest-logger.service <<EOF
[Unit]
Description=Speedtest Telemetry Logger (single run)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${APP_ROOT}
EnvironmentFile=${CONFIG_FILE}
ExecStart=${VENV_DIR}/bin/python ${APP_ROOT}/scripts/speedtest-logger.py
Restart=no

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/speedtest-logger.timer <<'EOF'
[Unit]
Description=Run Speedtest Telemetry Logger periodically

[Timer]
OnCalendar=*:0/5
Unit=speedtest-logger.service
Persistent=true

[Install]
WantedBy=timers.target
EOF

ok "Systemd units written."

log "Reloading systemd and enabling timer..."
systemctl daemon-reload
systemctl enable --now speedtest-logger.timer

ok "Host deployment complete."
ok "Check status with: sudo systemctl status speedtest-logger.timer speedtest-logger.service"
ok "Diag log: sudo tail -f /var/log/speedtest-diag.log"