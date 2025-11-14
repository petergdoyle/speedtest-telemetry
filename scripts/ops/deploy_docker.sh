#!/usr/bin/env bash
# Docker/Compose-based deployment for speedtest-telemetry
# Target: Ubuntu-like systems

set -euo pipefail

log()  { echo "[$(date -Iseconds)] $*"; }
ok()   { log "✅ $*"; }
warn() { log "⚠️  $*"; }
err()  { log "❌ $*" >&2; }

# Require root (run with sudo) since we install packages and manage docker
if [[ "${EUID}" -ne 0 ]]; then
  err "This script must be run as root. Try: sudo bash $0"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DATA_DIR="/var/lib/speedtest-telemetry"
LOG_FILE="/var/log/speedtest-diag.log"

log "Starting Docker-based deployment from repo root: ${REPO_ROOT}"

# 1) Install Docker + docker-compose
log "Installing docker.io and docker-compose (if needed)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y docker.io docker-compose

ok "Docker packages installed."

# 2) Ensure Docker service is running
log "Ensuring Docker daemon is running..."
systemctl enable --now docker
ok "Docker daemon is running."

# 3) Data + log dirs for persistence
log "Ensuring data and log paths exist..."
mkdir -p "${DATA_DIR}/raw"
touch "${DATA_DIR}/speedtest.csv"
touch "${LOG_FILE}"
# For homelab use, liberal permissions are acceptable. Adjust if needed.
chmod -R 777 "${DATA_DIR}"
chmod 666 "${LOG_FILE}"
ok "Data dir: ${DATA_DIR}, Log file: ${LOG_FILE}"

# 4) Build and run containers via docker-compose
if [[ ! -f "${REPO_ROOT}/docker-compose.yml" ]]; then
  err "docker-compose.yml not found in ${REPO_ROOT}. Aborting."
  exit 1
fi

log "Building Docker images..."
(cd "${REPO_ROOT}" && docker-compose build)

log "Starting speedtest-logger and speedtest-dashboard containers..."
(cd "${REPO_ROOT}" && docker-compose up -d)

ok "Docker deployment complete."
ok "Check containers: docker-compose ps (from ${REPO_ROOT})"
ok "Logger logs: docker-compose logs speedtest-logger"
ok "Dashboard:   open http://<host-ip>:8501 in your browser."