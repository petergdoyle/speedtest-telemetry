#!/usr/bin/env python3
# Server latency & DNS resolution diagnostic utility

import json
import socket
import subprocess
import time
import sys
import os

# Colors for terminal output
BOLD = "\033[1m"
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
BLUE = "\033[94m"
RESET = "\033[0m"

# Static fallback servers (Dayton/Denver region)
STATIC_SERVERS = [
    {"id": 56839, "name": "T-Mobile Fiber | Intrepid", "host": "speedtest.denver.intrepidfiber.com"},
    {"id": 8862, "name": "CenturyLink", "host": "denver.speedtest.centurylink.net"},
    {"id": 24079, "name": "ALLO - Denver", "host": "den11-speedtest01.as15108.com"},
    {"id": 61397, "name": "SUMOFIBER", "host": "st-denver.sumofiber.com"},
    {"id": 51010, "name": "Highline", "host": "stden.highlinefast.com"},
    {"id": 10051, "name": "Comcast", "host": "stosat-dvre-01.sys.comcast.net"},
    {"id": 63940, "name": "Sangoma", "host": "den-speedtest.net.sangoma.net"},
    {"id": 69490, "name": "Visionary Broadband", "host": "denver.speed.vcn.com"},
    {"id": 69052, "name": "RippleFiber", "host": "speedtest-denver.hyperfiber.com"},
    {"id": 64798, "name": "WiLine Networks", "host": "dende0004speedtestserver01.wiline.com"},
    {"id": 55925, "name": "Commnet Broadband", "host": "denver-speedtest.commnetbroadband.com"}
]

def check_speedtest_cli():
    paths = ["/usr/local/bin/speedtest", "speedtest"]
    for path in paths:
        try:
            subprocess.run([path, "--version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return path
        except Exception:
            continue
    return None

def get_discovered_servers(bin_path):
    if not bin_path:
        return []
    try:
        # Fetch closest servers via Ookla CLI
        res = subprocess.run(
            [bin_path, "-L", "--accept-license", "--accept-gdpr", "--format=json"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10
        )
        if res.returncode == 0 and res.stdout.strip():
            data = json.loads(res.stdout)
            return data.get("servers", [])
    except Exception:
        pass
    return []

def resolve_dns(host):
    start = time.time()
    try:
        ip = socket.gethostbyname(host)
        duration_ms = (time.time() - start) * 1000
        return ip, f"{duration_ms:.1f}ms", True
    except Exception as e:
        duration_ms = (time.time() - start) * 1000
        return "Unresolved", f"{duration_ms:.1f}ms", False

def ping_host(ip_or_host):
    try:
        # Run system ping command (2 packets, 1 sec timeout)
        res = subprocess.run(
            ["ping", "-c", "2", "-W", "1.5", ip_or_host],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        if res.returncode == 0:
            # Parse average latency and packet loss
            lines = res.stdout.splitlines()
            loss = "0"
            rtt = "N/A"
            for line in lines:
                if "packet loss" in line:
                    # Parse loss percentage
                    parts = line.split(",")
                    for part in parts:
                        if "packet loss" in part:
                            loss = part.replace("% packet loss", "").strip()
                if line.startswith("rtt") or line.startswith("round-trip"):
                    # e.g., round-trip min/avg/max/stddev = 15.616/17.201/18.804/1.22 ms
                    avg_part = line.split("=")[1].strip().split("/")[1]
                    rtt = f"{float(avg_part):.1f}ms"
            return rtt, loss
    except Exception:
        pass
    return "Timeout", "100"

def main():
    print(f"\n{BOLD}{BLUE}======================================================================{RESET}")
    print(f"  {BOLD}📡  SPEEDTEST TELEMETRY - NETWORK TARGET DIAGNOSTICS  📡{RESET}")
    print(f"{BOLD}{BLUE}======================================================================{RESET}\n")

    bin_path = check_speedtest_cli()
    if bin_path:
        print(f"ℹ️  Ookla CLI binary found: `{bin_path}`")
        print("🔍 Discovering closest speedtest servers dynamically...")
        servers = get_discovered_servers(bin_path)
    else:
        print("⚠️  Ookla CLI binary not found. Falling back to static list.")
        servers = []

    if not servers:
        print("ℹ️  Using static server list configuration.")
        servers = STATIC_SERVERS
    else:
        print(f"✅ Discovered {len(servers)} servers dynamically.")

    print(f"\n{BOLD}{'ID':<6} | {'Sponsor Name':<28} | {'Target Hostname':<38} | {'IP Address':<15} | {'DNS Lookup':<10} | {'Ping Lat':<8} | {'Loss%':<5} | {'Status':<6}{RESET}")
    print("-" * 132)

    succeeded_count = 0
    total_count = len(servers)

    for s in servers:
        sid = s.get("id", "N/A")
        name = s.get("name", "Unknown Sponsor")
        host = s.get("host", "unknown.host")
        
        # Trim name & host for clean table alignment
        if len(name) > 28:
            name = name[:25] + "..."
        if len(host) > 38:
            host = host[:35] + "..."

        # 1. DNS Resolution
        ip, dns_time, dns_ok = resolve_dns(s.get("host", ""))
        
        # 2. Ping Latency & Loss
        ping_lat = "N/A"
        loss_pct = "100"
        if dns_ok:
            ping_lat, loss_pct = ping_host(ip)

        # 3. Status determination
        if dns_ok and loss_pct != "100" and ping_lat != "Timeout":
            status = f"{GREEN}OK{RESET}"
            succeeded_count += 1
        else:
            status = f"{RED}FAIL{RESET}"

        print(f"{sid:<6} | {name:<28} | {host:<38} | {ip:<15} | {dns_time:<10} | {ping_lat:<8} | {loss_pct:<5} | {status:<6}")

    print(f"\n{BOLD}Diagnostic Summary:{RESET} {succeeded_count}/{total_count} servers reached successfully.")
    
    # Check if there is a severe DNS failure
    if succeeded_count == 0:
        print(f"\n{RED}❌ CRITICAL ERROR: All server connections failed. Check network link and DNS settings.{RESET}")
        sys.exit(1)
    elif succeeded_count < (total_count / 2):
        print(f"\n{YELLOW}⚠️  WARNING: High failure rate detected. Potential DNS/routing issues.{RESET}")
    else:
        print(f"\n{GREEN}✅ Network path diagnostics completed successfully.{RESET}")

if __name__ == "__main__":
    main()
