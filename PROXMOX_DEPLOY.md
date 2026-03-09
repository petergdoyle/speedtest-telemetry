# Proxmox Deployment Guide

This guide covers the best way to deploy the `speedtest-telemetry` project to a Proxmox VE homelab environment.

## Recommended Approach: Ubuntu LXC (Git Clone)

The most efficient way to run this on Proxmox is using a lightweight **LXC Container**.

### 1. Create the Container
1. Use an **Ubuntu 24.04** template.
2. **Crucial Settings**: In the LXC configuration -> **Options** -> **Features**, ensure both **FUSE** and **Nesting** are enabled. Docker requires nesting to run inside LXC.
3. Allocate at least 1GB of RAM and 8GB of storage.

### 2. Install Dependencies
Once the LXC is started and you are logged in (via shell or SSH):
```bash
# Update system
apt update && apt upgrade -y

# Install Docker and Make
apt install -y docker.io make git

# Ensure Docker starts on boot
systemctl enable --now docker
```

### 3. Deploy the Project
Clone your repository and use the built-in `Makefile` to handle the deployment:
```bash
# Clone the repository
git clone https://github.com/petergdoyle/speedtest-telemetry.git
cd speedtest-telemetry

# Verify environment
make setup

# Build and Run
make build

### 4. Optional: Enable Hardware Discovery (Recommended)
For the most accurate results and to allow the logger to see your physical Ethernet and Wi-Fi interfaces, you should enable **Host Networking**.

1. Edit `docker-compose.yml`:
   ```bash
   nano docker-compose.yml
   ```
2. **Uncomment** the line `network_mode: host`.
3. **Comment out** the `ports:` section (port mapping is not needed in host mode).

### 5. Start the Stack
```bash
make run
```

### 6. Access the Dashboard
The dashboard will be available at: `http://<LXC_IP_ADDRESS>:8501`

---

## 🔧 Proxmox Specific Optimization
- **Hardware Privileges**: If you want the container to access specific Wi-Fi hardware, ensure the LXC is marked as **Unprivileged: No** (if current settings fail) or use **Device Passthrough** for the specific WLAN card.
- **Kernel Modules**: The stack includes `kmod` and `wireless-tools` to assist in detecting link speeds and bands directly from the host.

## Alternative: Virtual Machine (VM)
If you prefer a full VM (QEMU), follow the exact same "Deploy the Project" steps above. You do not need the "Nesting/FUSE" features for a VM as it has a dedicated kernel.

## Updating the Deployment
To update your telemetry stack on Proxmox whenever you push changes from your local machine:
```bash
cd speedtest-telemetry
git pull
make build
make run
```
