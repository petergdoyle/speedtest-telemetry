.PHONY: help build run stop logs shell test clean setup env

IMAGE_NAME = speedtest-telemetry
CONTAINER_NAME = speedtest-telemetry

# Show this help message
help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@awk '/^[a-zA-Z\-_0-9]+:/ { \
		helpMessage = match(lastLine, /^# (.*)/); \
		if (helpMessage) { \
			helpCommand = substr($$1, 0, index($$1, ":")-1); \
			helpDesc = substr(lastLine, RSTART + 2, RLENGTH); \
			printf "  %-15s %s\n", helpCommand, helpDesc; \
		} \
	} \
	{ lastLine = $$0 }' $(MAKEFILE_LIST)

# Verify prerequisites (Docker)
env:
	@echo "🔍 Checking for Docker and Docker Compose..."
	@which docker >/dev/null || (echo "❌ Docker is not installed. Please install Docker Desktop or Docker Engine." && exit 1)
	@docker compose version >/dev/null || (echo "❌ Docker Compose is not installed or available via 'docker compose'." && exit 1)
	@echo "✅ All prerequisites met. You are ready to run 'make build' and 'make run'!"

# Alias for env
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

# Follow the container logs (useful for checking systemd init errors)
logs:
	docker compose logs -f

# Follow the telemetry logger logs specifically 
logger-logs:
	docker exec $(CONTAINER_NAME) journalctl -u speedtest-logger.service -f

# Follow the dashboard logs specifically
dashboard-logs:
	docker exec $(CONTAINER_NAME) journalctl -u speedtest-dashboard.service -f

# Enter the running container
shell:
	docker exec -it $(CONTAINER_NAME) /bin/bash

# Force trigger a manual speedtest run
test:
	docker exec $(CONTAINER_NAME) systemctl start speedtest-logger.service

# Run a comprehensive diagnostic check inside the container
debug:
	@chmod +x scripts/debug-systemd.sh
	@docker exec $(CONTAINER_NAME) bash -c "chmod +x /app/scripts/debug-systemd.sh && /app/scripts/debug-systemd.sh"

# Remove the container and the associated data volume (Destructive!)
clean:
	docker compose down -v
	docker rmi $(IMAGE_NAME) || true

