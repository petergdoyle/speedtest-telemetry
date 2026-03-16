Proxmox Deployment Guide: speedtest-telemetry
This guide documents the "best practice" deployment of the speedtest-telemetry project within a Proxmox LXC container, including network optimization via Omada and automated service management.

1. Network Strategy (Omada Controller)
To ensure the telemetry dashboard remains accessible and prevents IP conflicts, we implement a "Container ID = IP Address" strategy.

DHCP Partitioning

Navigate to Settings > Wired Networks > LAN.

Modify the DHCP Range for the Servers VLAN:

Old Range: 192.168.20.1 - 192.168.20.254

New Range: 192.168.20.200 - 192.168.20.254

Why? This reserves the lower IP range (.2 through .199) for static/fixed assignments, preventing the router from "accidentally" giving a container's ID-based IP to a temporary device.

Fixed IP Reservation

Identify the MAC address of the LXC in Proxmox (Network tab).

In Omada, go to Clients, select the container, and under Config, enable Use Fixed IP Address.

Set the IP to match the Proxmox CT ID (e.g., CT 104 → 192.168.20.104).

2. Proxmox LXC Configuration
Create the container using the following specifications for optimal performance and Docker compatibility.

Basic Settings

OS Template: debian-13-standard (Trixie).

Disk: 16 GB (Enable Discard if using SSD storage).

CPU: 2 Cores (Provides headroom for concurrent testing and dashboard rendering).

Memory: 1024 MiB RAM / 512 MiB Swap.

SSH: Paste your id_ed25519.pub to allow passwordless access from your management machine.

Required Features ("Inception" Mode)

After creation, you must enable these features for Docker to function inside the LXC:

Go to LXC > Options > Features > Edit.

Check Nesting (allows the LXC to run containers).

Check keyctl (required for Docker's security layer).

Check FUSE (prevents file system driver errors).

3. OS & Docker Preparation
SSH into the container (ssh root@192.168.20.104) and run the following to install the stack:

Bash
# Update System
apt update && apt upgrade -y

# Install Prerequisites
apt install -y curl git make

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
4. Project Deployment
Clone the repository and prepare the data environment.

Bash
git clone https://github.com/petergdoyle/speedtest-telemetry.git
cd speedtest-telemetry

# Create the data directory for the bind mount
mkdir -p data
chmod 777 data
Docker Compose Optimization

Ensure your docker-compose.yml uses Host Networking to get accurate line-speed results:

YAML
services:
  speedtest-telemetry:
    build: .
    container_name: speedtest-telemetry
    restart: unless-stopped
    network_mode: "host"  # Bypasses Docker bridge overhead
    privileged: true      # Required for internal systemd
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
      - ./data:/var/lib/speedtest-telemetry
    ports:
      - "8501:8501"
Build and Launch

Bash
make build
make run
5. Host-Level Automation (Systemd)
To ensure the telemetry stack starts automatically when the Proxmox node reboots, create a systemd service on the LXC host OS (not inside Docker).

Create file: nano /etc/systemd/system/speedtest-telemetry.service

Paste content:

Ini, TOML
[Unit]
Description=Speedtest Telemetry Docker Stack
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/root/speedtest-telemetry
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
Enable service:

Bash
systemctl daemon-reload
systemctl enable --now speedtest-telemetry.service
6. Access & Proxying
Direct Access: http://192.168.20.104:8501

Nginx Proxy Manager: * Add a new Proxy Host.

Domain Name: speedtest.cleverfish.lan

Forward Host: 192.168.20.104

Forward Port: 8501

Websockets Support: Enabled.