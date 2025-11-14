#!/usr/bin/env python3
"""
speedtest_logger.py

Periodic telemetry logger for Ookla-style speedtest results.

Responsibilities:
- Ensure the CSV log exists and has the correct header.
- Pre-check local network state (interface, IP, default route, gateway reachability).
- Run a speedtest CLI command that emits a single CSV line.
- Append ONLY successful runs with valid CSV format to the main CSV log.
- Log structured diagnostics (JSON lines) for failures with reason codes.

Intended to be triggered by a systemd timer instead of the legacy speedtest-logger.sh.
"""

import json
import os
import shlex
import subprocess
import sys
from datetime import datetime
from typing import Dict, Optional, Tuple

# ---------- Configuration ----------

CSV_PATH = os.environ.get("SPEEDTEST_CSV_PATH", "/var/lib/speedtest-telemetry/speedtest.csv")
DIAG_LOG_PATH = os.environ.get("SPEEDTEST_DIAG_LOG_PATH", "/var/log/speedtest-diag.log")
IFACE = os.environ.get("SPEEDTEST_IFACE", "wlp2s0")

# Command that outputs a single CSV line for each successful run
SPEEDTEST_CMD = os.environ.get(
    "SPEEDTEST_CMD",
    "/usr/local/bin/speedtest-telemetry --format=csv"
)

# If not set, gateway IP will be inferred from `ip route`
GATEWAY_IP = os.environ.get("SPEEDTEST_GATEWAY_IP", "")

# CSV header derived from your existing log file
CSV_HEADER = (
    "timestamp,download_mbps,upload_mbps,ping_ms,jitter_ms,packet_loss,"
    "server_name,server_id,isp,gw_ping_ms,gw_loss_pct,cf_ping_ms,cf_loss_pct,"
    "g_ping_ms,g_loss_pct,dns_ms,http_ms,wifi_iface,wifi_ssid,wifi_band,status,error"
)
CSV_FIELD_COUNT = len(CSV_HEADER.split(","))


# ---------- Utility helpers ----------

def iso_now() -> str:
    return datetime.utcnow().isoformat(timespec="seconds") + "Z"


def run_cmd(cmd: str) -> Tuple[int, str, str]:
    """Run a shell command safely and capture exit code, stdout, stderr."""
    try:
        proc = subprocess.run(
            shlex.split(cmd),
            capture_output=True,
            text=True,
            check=False,
        )
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
    except Exception as e:
        return 1, "", f"{type(e).__name__}: {e}"


def append_line(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(text.rstrip("\n") + "\n")


def log_diag(record: Dict) -> None:
    """
    Write a JSON line to the diagnostics log and also echo to stdout
    so journald/systemd sees the same message.
    """
    record.setdefault("ts", iso_now())
    line = json.dumps(record, sort_keys=True)
    os.makedirs(os.path.dirname(DIAG_LOG_PATH), exist_ok=True)
    append_line(DIAG_LOG_PATH, line)
    print(line)


def ensure_csv_header(path: str) -> None:
    """
    Ensure the CSV file exists and contains the correct header.
    If the file doesn't exist, create it and write the header.
    If it exists but the first line isn't the expected header, rewrite header + keep data.
    """
    os.makedirs(os.path.dirname(path), exist_ok=True)

    if not os.path.exists(path):
        with open(path, "w", encoding="utf-8") as f:
            f.write(CSV_HEADER + "\n")
        return

    # File exists: check first line
    try:
        with open(path, "r", encoding="utf-8") as f:
            first_line = f.readline().strip()
            rest = f.read()
    except Exception as e:
        # If unreadable → recreate with just header
        log_diag({
            "level": "ERROR",
            "phase": "init",
            "reason": "CSV_READ_ERROR",
            "detail": str(e),
            "csv_path": path,
        })
        with open(path, "w", encoding="utf-8") as f:
            f.write(CSV_HEADER + "\n")
        return

    if first_line == CSV_HEADER:
        # Already correct
        return

    # Rewrite file with correct header + non-header content
    with open(path, "w", encoding="utf-8") as f:
        f.write(CSV_HEADER + "\n")
        for line in rest.splitlines():
            if not line.strip():
                continue
            if line.strip().startswith("timestamp"):
                # Drop any old/duplicate header lines
                continue
            f.write(line.rstrip("\n") + "\n")

    log_diag({
        "level": "INFO",
        "phase": "init",
        "reason": "CSV_HEADER_FIXED",
        "csv_path": path,
    })


# ---------- Network state checks ----------

def get_default_route() -> Tuple[Optional[str], Optional[str]]:
    """
    Return (gateway_ip, dev) from `ip route show default`.
    """
    rc, out, err = run_cmd("ip route show default")
    if rc != 0 or not out:
        return None, None

    # Expect a line like: "default via 192.168.12.1 dev wlp2s0 ..."
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 5 and parts[0] == "default" and parts[1] == "via":
            gw = parts[2]
            dev = parts[4]
            return gw, dev

    return None, None


def check_iface(iface: str) -> Tuple[bool, str, Dict]:
    """
    Check that the interface exists and is UP.
    Returns (ok, reason_code, extra_info).
    """
    rc, out, err = run_cmd(f"ip link show {iface}")
    if rc != 0:
        return False, "IFACE_NOT_FOUND", {"stderr": err}

    extra = {"ip_link": out}

    if "state DOWN" in out:
        return False, "IFACE_DOWN", extra

    return True, "OK", extra


def check_ip_address(iface: str) -> Tuple[bool, str, Dict]:
    """
    Check that the interface has an IPv4 address assigned.
    """
    rc, out, err = run_cmd(f"ip -4 addr show dev {iface}")
    if rc != 0:
        return False, "ADDR_CMD_ERROR", {"stderr": err}

    extra = {"ip_addr": out}
    if "inet " not in out:
        return False, "NO_IP_ADDR", extra

    return True, "OK", extra


def check_gateway(gateway_ip: str) -> Tuple[bool, str, Dict]:
    """
    Ping the gateway briefly to see if it's reachable.
    """
    rc, out, err = run_cmd(f"ping -c 1 -W 2 {gateway_ip}")
    extra = {"ping_stdout": out, "ping_stderr": err}
    if rc != 0:
        return False, "GATEWAY_UNREACH", extra
    return True, "OK", extra


# ---------- Speedtest execution ----------

def run_speedtest() -> Tuple[int, str, str]:
    """
    Run the speedtest command and capture exit code, stdout, stderr.
    stdout should be a single CSV line on success.
    """
    return run_cmd(SPEEDTEST_CMD)


def classify_speedtest_error(stderr: str) -> str:
    """
    Map known speedtest stderr patterns to reason codes.
    """
    if "NotFoundException" in stderr:
        return "SPEEDTEST_IFACE_NOT_FOUND"
    if "Network unreachable" in stderr:
        return "SPEEDTEST_NET_UNREACH"
    if "timeout" in stderr.lower():
        return "SPEEDTEST_TIMEOUT"
    if "permission denied" in stderr.lower():
        return "SPEEDTEST_PERMISSION"
    if not stderr:
        return "SPEEDTEST_UNKNOWN"
    return "SPEEDTEST_ERROR"


def validate_csv_line(line: str) -> bool:
    """
    Basic sanity check: ensure the speedtest line has the expected number of CSV fields.
    """
    # Allow for trailing commas by stripping whitespace
    fields = [f.strip() for f in line.split(",")]
    return len(fields) == CSV_FIELD_COUNT


# ---------- Main workflow ----------

def main() -> int:
    ts = iso_now()

    # 0) Ensure CSV file exists with correct header
    ensure_csv_header(CSV_PATH)

    # 1) Determine gateway IP if not provided
    gw_ip = GATEWAY_IP
    gw_dev = None
    if not gw_ip:
        gw_ip, gw_dev = get_default_route()

    # 2) Pre-checks
    precheck_info: Dict[str, Dict] = {}

    ok_iface, reason_iface, extra_iface = check_iface(IFACE)
    precheck_info["iface"] = extra_iface

    if not ok_iface:
        log_diag({
            "ts": ts,
            "level": "ERROR",
            "phase": "precheck",
            "reason": reason_iface,
            "iface": IFACE,
            **extra_iface,
        })
        # Exit 0 so systemd timer doesn't treat this as a unit failure
        return 0

    ok_ip, reason_ip, extra_ip = check_ip_address(IFACE)
    precheck_info["ip"] = extra_ip

    if not ok_ip:
        log_diag({
            "ts": ts,
            "level": "ERROR",
            "phase": "precheck",
            "reason": reason_ip,
            "iface": IFACE,
            **extra_ip,
        })
        return 0

    if not gw_ip:
        log_diag({
            "ts": ts,
            "level": "ERROR",
            "phase": "precheck",
            "reason": "NO_DEFAULT_ROUTE",
            "iface": IFACE,
        })
        return 0

    ok_gw, reason_gw, extra_gw = check_gateway(gw_ip)
    precheck_info["gateway"] = extra_gw

    if not ok_gw:
        log_diag({
            "ts": ts,
            "level": "ERROR",
            "phase": "precheck",
            "reason": reason_gw,
            "iface": IFACE,
            "gateway_ip": gw_ip,
            **extra_gw,
        })
        return 0

    # 3) Run speedtest
    rc, out, err = run_speedtest()

    if rc != 0:
        reason = classify_speedtest_error(err)
        log_diag({
            "ts": ts,
            "level": "ERROR",
            "phase": "speedtest",
            "reason": reason,
            "iface": IFACE,
            "gateway_ip": gw_ip,
            "stderr": err[:500],  # truncate for log sanity
        })
        return 0

    if not out:
        log_diag({
            "ts": ts,
            "level": "WARN",
            "phase": "speedtest",
            "reason": "EMPTY_OUTPUT",
            "iface": IFACE,
            "gateway_ip": gw_ip,
        })
        return 0

    # 4) Validate CSV shape before appending
    if not validate_csv_line(out):
        log_diag({
            "ts": ts,
            "level": "ERROR",
            "phase": "speedtest",
            "reason": "BAD_CSV_FORMAT",
            "iface": IFACE,
            "gateway_ip": gw_ip,
            "line_sample": out[:500],
        })
        return 0

    # 5) Append successful CSV line
    append_line(CSV_PATH, out)
    log_diag({
        "ts": ts,
        "level": "INFO",
        "phase": "speedtest",
        "reason": "OK",
        "iface": IFACE,
        "gateway_ip": gw_ip,
    })
    return 0


if __name__ == "__main__":
    sys.exit(main())