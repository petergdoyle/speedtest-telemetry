FROM ubuntu:24.04

# Avoid interactive prompts during apt install
ENV DEBIAN_FRONTEND=noninteractive

# Update and install system dependencies (including systemd, networking tools, and python)
RUN apt-get update && apt-get install -y \
    systemd \
    systemd-sysv \
    cron \
    curl \
    jq \
    dnsutils \
    iproute2 \
    iw \
    wireless-tools \
    kmod \
    python3 \
    python3-pip \
    python3-venv \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Install Ookla Speedtest CLI using pre-compiled binary
RUN curl -o speedtest.tgz https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz && \
    tar xzvf speedtest.tgz -C /usr/local/bin speedtest && \
    rm speedtest.tgz && \
    chmod +x /usr/local/bin/speedtest

# Create working directories
WORKDIR /app
RUN mkdir -p /var/lib/speedtest-telemetry/raw

# Copy telemetry script and dashboard
COPY scripts/ /app/scripts/
COPY dashboard/ /app/dashboard/

# Make telemetry script executable
RUN chmod +x /app/scripts/speedtest-log.sh

# Setup Python environment for dashboard
RUN python3 -m venv /app/.venv
# We install dependencies via venv
RUN /app/.venv/bin/pip install --upgrade pip
RUN if [ -f /app/dashboard/requirements.txt ]; then /app/.venv/bin/pip install -r /app/dashboard/requirements.txt; fi

# Copy Systemd Services
# We will use system-level services for Docker rather than user-level
COPY systemd/system/ /etc/systemd/system/

# Enable the systemd services
RUN systemctl enable speedtest-logger.timer && \
    systemctl enable speedtest-dashboard.service


RUN systemctl set-default multi-user.target

# Expose Streamlit port
EXPOSE 8501

# Start systemd
CMD ["/sbin/init"]
