# Speedtest Telemetry Makefile
# Reorganized for Docker, Local, and Diagnostics operations

IMAGE_NAME = speedtest-telemetry
CONTAINER_NAME = speedtest-telemetry

# Colors for terminal formatting
BOLD   := \033[1m
BLUE   := \033[34m
YELLOW := \033[33m
GREEN  := \033[32m
RESET  := \033[0m

.PHONY: help env setup build run stop logs logger-logs dashboard-logs shell test debug clean-logs clean \
        local-env local-run local-dashboard local-list local-diagnose docker-list docker-diagnose

# Show this help message grouped by scope
help:
	@echo "$(BOLD)📶 SPEEDTEST TELEMETRY IACOPS SYSTEM$(RESET)"
	@echo "--------------------------------------------------------"
	@echo "Usage: make [target]"
	@echo ""
	@echo "$(BLUE)🐳 DOCKER CONTAINER OPERATIONS:$(RESET)"
	@echo "  build              Build the Docker image"
	@echo "  run                Start the container in detached mode (host network)"
	@echo "  stop               Stop and remove the container"
	@echo "  logs               Follow container systemd logs"
	@echo "  logger-logs        Follow speedtest logger service logs specifically"
	@echo "  dashboard-logs     Follow streamlit dashboard service logs specifically"
	@echo "  shell              Enter running container terminal shell"
	@echo "  clean-logs         Clear all accumulated telemetry data inside container"
	@echo "  clean              Destroy container and data volume completely"
	@echo ""
	@echo "$(YELLOW)💻 LOCAL/WORKSTATION OPERATIONS:$(RESET)"
	@echo "  local-env          Verify local python/pip & speedtest CLI presence"
	@echo "  local-run          Run the speedtest telemetry script locally on host"
	@echo "  local-dashboard    Run Streamlit dashboard locally on port 8501"
	@echo "  local-list         List closest Ookla speedtest servers on this workstation"
	@echo "  local-diagnose     Run latency/DNS diagnostics on servers locally"
	@echo ""
	@echo "$(GREEN)🔍 CONTAINER TELEMETRY & DIAGNOSTICS:$(RESET)"
	@echo "  test               Force-trigger speedtest-logger run inside container"
	@echo "  debug              Run container network & systemd status check"
	@echo "  docker-list        List closest Ookla speedtest servers inside container"
	@echo "  docker-diagnose    Run latency/DNS diagnostics inside container"
	@echo ""

# Verify prerequisites (Docker)
env:
	@echo "🔍 Checking for Docker and Docker Compose..."
	@which docker >/dev/null || (echo "❌ Docker is not installed. Please install Docker." && exit 1)
	@docker compose version >/dev/null || (echo "❌ Docker Compose is not installed or available via 'docker compose'." && exit 1)
	@echo "✅ Docker environment is ready."

setup: env

# Build the Docker image
build:
	docker compose build

# Start the container in detached mode
run:
	docker compose up -d

# Stop the container
stop:
	docker compose down

# Follow the container logs
logs:
	docker compose logs -f

# Follow the telemetry logger logs specifically
logger-logs:
	docker exec -it $(CONTAINER_NAME) journalctl -u speedtest-logger.service -f

# Follow the dashboard logs specifically
dashboard-logs:
	docker exec -it $(CONTAINER_NAME) journalctl -u speedtest-dashboard.service -f

# Enter the running container
shell:
	docker exec -it $(CONTAINER_NAME) /bin/bash

# Force trigger a manual speedtest run inside container
test:
	docker exec -it $(CONTAINER_NAME) systemctl start speedtest-logger.service

# Run a comprehensive diagnostic check inside the container
debug:
	@chmod +x scripts/debug-systemd.sh
	@docker exec $(CONTAINER_NAME) bash -c "chmod +x /app/scripts/debug-systemd.sh && /app/scripts/debug-systemd.sh"

# Clear the accumulated telemetry logs from the running container
clean-logs:
	@echo "⚠️  Clearing telemetry logs from inside the container..."
	docker exec $(CONTAINER_NAME) bash -c "rm -f /var/lib/speedtest-telemetry/speedtest.csv /var/lib/speedtest-telemetry/errors.log /var/lib/speedtest-telemetry/raw/*.json"
	@echo "✅ Logs cleared."

# Remove the container and the associated data volume (Destructive!)
clean:
	docker compose down -v
	docker rmi $(IMAGE_NAME) || true


# --- LOCAL OPERATIONS ---

# Verify local workstation environment dependencies
local-env:
	@echo "🔍 Checking local dependencies..."
	@which python3 >/dev/null || (echo "❌ python3 not found." && exit 1)
	@which speedtest >/dev/null || (echo "⚠️  speedtest CLI not found. Run 'brew install speedtest-cli' (Ookla version) or use docker commands." && exit 1)
	@python3 -m pip --version >/dev/null 2>&1 || echo "⚠️  pip not found. You may need to install pip for python3."
	@echo "✅ Local python & speedtest CLI are available."

# Run telemetry logger directly on workstation
local-run: local-env
	@echo "🏃 Running telemetry logger locally..."
	SPEEDTEST_DATA="./data" ./scripts/speedtest-log.sh

# Run Streamlit dashboard locally on port 8501
local-dashboard:
	@echo "📊 Starting local dashboard..."
	@python3 -m pip install -r dashboard/requirements.txt streamlit-autorefresh >/dev/null 2>&1 || true
	SPEEDTEST_CSV="./data/speedtest.csv" SPEEDTEST_RAW="./data/raw" streamlit run dashboard/streamlit_app.py --server.port 8501

# List closest servers locally
local-list: local-env
	speedtest -L

# Run diagnostic script locally
local-diagnose: local-env
	@python3 scripts/diagnose-servers.py


# --- DOCKER DIAGNOSTICS ---

# List closest servers inside container
docker-list:
	docker exec -it $(CONTAINER_NAME) speedtest -L

# Run diagnostics inside container
docker-diagnose:
	docker exec -it $(CONTAINER_NAME) python3 /app/scripts/diagnose-servers.py
