# Proxmox Deployment Guide: speedtest-telemetry

This guide documents the "best practice" deployment of the `speedtest-telemetry` project within a Proxmox VE homelab environment, including network optimization via Omada and automated service management.

## 1. Create the Proxmox LXC Container

Create a lightweight **LXC Container** for the most efficient deployment.

### Recommended Specifications
- **OS Template**: `debian-13-standard` (Trixie) or `ubuntu-24.04-standard`.
- **Disk**: 16 GB (Enable **Discard** if using SSD storage).
- **CPU**: 2 Cores (Recommended for concurrent testing and dashboard rendering).
- **Memory**: 1024 MiB RAM / 512 MiB Swap.
- **SSH**: Paste your `id_ed25519.pub` to allow passwordless access.

### Required Features ("Inception" Mode)
After creation, you **must** enable these features for Docker to function inside the LXC:
1. Go to **LXC > Options > Features > Edit**.
2. Check **Nesting** (allows the LXC to run containers).
3. Check **keyctl** (required for Docker's security layer).
4. Check **FUSE** (prevents file system driver errors).

---

## 2. Network Strategy (Omada Controller)

Once the container is created, configure the network settings to ensure the telemetry dashboard remains accessible and prevents IP conflicts.

### DHCP Partitioning
1. Navigate to **Settings > Wired Networks > LAN**.
2. Modify the **DHCP Range** for your Servers VLAN (e.g., `192.168.20.1 - 192.168.20.254`).
3. Set a new range starting higher (e.g., `192.168.20.200 - 192.168.20.254`).
   > [!NOTE]
   > This reserves the lower IP range for static/fixed assignments, preventing the router from "accidentally" giving a container's ID-based IP to a temporary device.

### Fixed IP Reservation
1. Identify the **MAC address** of the LXC in Proxmox (**Network** tab).
2. In Omada, go to **Clients**, select the container, and under **Config**, enable **Use Fixed IP Address**.
3. Set the IP to match the Proxmox CT ID (e.g., CT `104` → `192.168.20.104`).

---

## 3. OS & Docker Preparation

SSH into the container (e.g., `ssh root@192.168.20.104`) and run the following:

```bash
# Update System
apt update && apt upgrade -y

# Install Prerequisites
apt install -y curl git make

# Install Docker using the official convenience script
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh

# Ensure Docker starts on boot
systemctl enable --now docker
```

---

## 4. Project Deployment

Clone the repository and prepare the data environment:

```bash
# Clone the repository
git clone https://github.com/petergdoyle/speedtest-telemetry.git
cd speedtest-telemetry

# Create the data directory for the bind mount
mkdir -p data
chmod 777 data

# Verify environment
make setup
```

---

## 5. Optimization (Docker Compose)

### Host Networking
To get the most accurate line-speed results and allow the logger to see physical interfaces, use **Host Networking**.

1. Edit your `docker-compose.yml`:
   ```yaml
   services:
     speedtest-telemetry:
       network_mode: "host"  # Bypasses Docker bridge overhead
       privileged: true      # Required for internal systemd
       volumes:
         - /sys/fs/cgroup:/sys/fs/cgroup:rw
         - ./data:/var/lib/speedtest-telemetry
   ```
2. **Comment out** the `ports:` section if using `network_mode: host`.

---

## 6. Host-Level Automation (Systemd)

To ensure the telemetry stack starts automatically when the Proxmox node reboots, create a systemd service on the **LXC host OS** (not inside Docker).

1. Create the service file:
   `nano /etc/systemd/system/speedtest-telemetry.service`

2. Paste the following configuration:
   ```ini
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
   ```

3. Enable the service:
   ```bash
   systemctl daemon-reload
   systemctl enable --now speedtest-telemetry.service
   ```

---

## 7. Access & Proxying

- **Direct Access**: `http://<LXC_IP_ADDRESS>:8501`
- **Nginx Proxy Manager (NPM)**:
  - **Domain Name**: e.g., `speedtest.yourdomain.lan`
  - **Forward Host**: `<LXC_IP_ADDRESS>`
  - **Forward Port**: `8501`
  - **Websockets Support**: Enabled (Required for Streamlit).

---

## Updating the Deployment

To update your telemetry stack whenever you push changes:

```bash
cd speedtest-telemetry
git pull
make build
make run
```
