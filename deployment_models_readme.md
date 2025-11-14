# Deployment Models for Speedtest Telemetry

This document outlines the two supported deployment models for running the **speedtest-telemetry** system:

1. **Host-Based Deployment using systemd ("Bare-Metal/VM")**
2. **Container-Based Deployment using Docker and Docker Compose**

Each model is optimized for different environments and operational preferences. This guide explains the differences, tradeoffs, and when you might choose one approach over the other.

---

## 1. Host-Based Deployment (systemd Services + Timers)

A host-based deployment runs the Python logger and optional dashboard **directly on the operating system** (Ubuntu, Debian, etc.). It uses the OS-native process manager: **systemd**.

### Key Components

* `speedtest-logger.service` — runs the logger once
* `speedtest-logger.timer` — schedules execution (e.g., every 5 minutes)
* `speedtest-dashboard.service` (optional) — runs the Streamlit dashboard
* Optional `stayawake.service` — prevents the system from sleeping

### Advantages

* **Native OS integration** using systemd's timers, journaling, and supervision.
* **Clear observability** via `systemctl status` and `journalctl`.
* **Precise scheduling** with `OnCalendar` expressions.
* **No container overhead**—simple, fast, lightweight.
* Excellent for a dedicated homelab machine such as a mini-PC.

### Disadvantages

* Less portable across different systems.
* The host needs Python, pip, and dependencies installed.
* More effort to reproduce identical environments across machines.

### Best For

* ACEMagic or other home lab nodes
* Virtual machines
* Environments where systemd is preferred or required

---

## 2. Container Deployment (Docker + Docker Compose)

In this model, each major component runs inside a dedicated container:

* **speedtest-logger container** — uses an internal loop to run the logger at intervals
* **speedtest-dashboard container** — serves the Streamlit web UI

Persistent data is stored on the host using mounted volumes:

* `/var/lib/speedtest-telemetry` — CSV files and raw JSON
* `/var/log/speedtest-diag.log` — diagnostics log

### Advantages

* **Highly portable** — runs the same on macOS, Linux, VM, or homelab server.
* **Dependency isolation** — Python packages and tools live inside the container.
* Simplifies multi-service deployments via Docker Compose.
* Ready for future Kubernetes deployment.
* No need to install Python or dependencies on the host itself.

### Disadvantages

* Scheduling becomes container-driven (simple loop or cron).
* Requires Docker and Compose to be installed.
* Logs and observability handled via Docker (`docker logs`).
* Slightly more complex architecture for a simple host.

### Best For

* Development environments (MacBook + Ubuntu VM)
* Multi-node setups
* Deployments that may evolve into Kubernetes

---

## Unified Design Principle: One-Shot Logger

Regardless of deployment model, **`speedtest-logger.py` is designed to run once**, log one test, then exit.

The *scheduler* changes based on environment:

| Environment    | Scheduler                                    |
| -------------- | -------------------------------------------- |
| Host / VM      | systemd timer (`OnCalendar`)                 |
| Docker Compose | Loop inside container (`run-logger-loop.sh`) |
| Kubernetes     | CronJob (future)                             |

This keeps application logic clean and allows maximum flexibility.

---

## Which Deployment Should You Choose?

### Choose **Host-Based systemd** if you want:

* The simplest and most native setup on a dedicated server.
* Tight integration with OS monitoring tools.
* Clear logging through `journalctl`.
* Cron-like scheduling with systemd timers.

### Choose **Docker Compose** if you want:

* Portability between development and production.
* Isolation from host Python environments.
* Easy replication across multiple machines.
* A path toward Kubernetes.

---

## Recommended Approach

We recommend maintaining **both** deployment models:

* **Host-based systemd** for bare-metal servers and simple homelab nodes.
* **Docker Compose** for development, testing, and portable deployments.

Each model remains clean, minimal, and purpose-built — without trying to force systemd inside a container or build overly complicated host dependencies.

---

## Deployment Scripts

To make setup repeatable and idempotent, the project provides two helper scripts under `scripts/ops/`:

* `scripts/ops/deploy_host.sh`
  Host-based deployment using systemd. This script:

  * Installs required packages (Python, venv, curl, etc.) on Ubuntu.
  * Creates a dedicated `speedtest` system user.
  * Copies the repo into `/opt/speedtest-telemetry`.
  * Creates and populates a Python virtual environment under `/opt/speedtest-telemetry/.venv`.
  * Ensures `/var/lib/speedtest-telemetry` and `/var/log/speedtest-diag.log` exist with correct ownership.
  * Installs and enables `speedtest-logger.service` and `speedtest-logger.timer` under `/etc/systemd/system`.

* `scripts/ops/deploy_docker.sh`
  Container-based deployment using Docker and Docker Compose. This script:

  * Installs `docker.io` and `docker-compose` on Ubuntu if needed.
  * Ensures `/var/lib/speedtest-telemetry` and `/var/log/speedtest-diag.log` exist on the host for persistence.
  * Builds the `speedtest-logger` and `speedtest-dashboard` images from `Dockerfile.logger` and `Dockerfile.dashboard`.
  * Starts the logger and dashboard via `docker-compose.yml`.

Both scripts are designed to be **idempotent**: if they fail halfway (for example, due to a network issue installing packages), you can correct the problem and re-run them. They will re-apply configuration safely.

When getting started on a new machine, choose one of:

* `sudo bash scripts/ops/deploy_host.sh` — for a system-wide, systemd-managed deployment.
* `sudo bash scripts/ops/deploy_docker.sh` — for a containerized deployment managed by Docker Compose.

---

## Summary

Two deployment models, one shared application core:

* **Host:** systemd timer → runs logger → logs results → dashboard optional
* **Docker:** loop entrypoint → repeats at intervals → dashboard container optional

Both models write to the same persistent data directories and support identical dashboards, logs, and behavior.

This separation of concerns ensures flexibility today and scalability tomorrow (including Kubernetes support).

Two deployment models, one shared application core:

* **Host:** systemd timer → runs logger → logs results → dashboard optional
* **Docker:** loop entrypoint → repeats at intervals → dashboard container optional

Both models write to the same persistent data directories and support identical dashboards, logs, and behavior.

This separation of concerns ensures flexibility today and scalability tomorrow (including Kubernetes support).

---

Future revisions to this document. 
* Deployment scripts
* Kubernetes YAML
* System diagrams
* Operational notes
