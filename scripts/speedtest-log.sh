#!/usr/bin/env bash
# Speedtest + ICMP/DNS/HTTP telemetry logger (portable server discovery)
# - Dynamically discovers nearby servers via `speedtest -L` (parse ID column)
# - Tries servers in order with retries, timeouts, and fallback
# - Logs CSV (with server name & id), raw JSON per run, and errors.log
# - Uses flock to avoid overlap from cron

set -u

############################
# CONFIG
############################
SERVER_LIMIT=12             # how many server IDs to try from `speedtest -L`
TRIES_PER_SERVER=2          # attempts before moving to next server
GLOBAL_MAX_TRIES=10         # safety cap across all servers
CMD_TIMEOUT=60              # seconds per attempt
BACKOFF_BASE=5              # seconds; grows linearly per attempt

# System-wide locations (match service hardening)
BASE_DIR="${SPEEDTEST_DATA:-/var/lib/speedtest-telemetry}"
CSV="$BASE_DIR/speedtest.csv"
RAW_DIR="$BASE_DIR/raw"
ERR_LOG="$BASE_DIR/errors.log"
LOCK="$BASE_DIR/.speedtest.lock"

# Telemetry targets
DNS_TARGET="one.one.one.one"          # resolves via 1.1.1.1
HTTP_URL="https://www.google.com/generate_204"

# Static fallback (used only if dynamic discovery fails)
STATIC_SERVERS=(56839 8862 24079 61397 51010 23971 10051 16797 53975 14861 47683)

############################
# SETUP
############################
mkdir -p "$BASE_DIR" "$RAW_DIR"

# Find Ookla CLI
if command -v /usr/local/bin/speedtest >/dev/null 2>&1; then
  BIN="/usr/local/bin/speedtest"
elif command -v speedtest >/dev/null 2>&1; then
  BIN="$(command -v speedtest)"
else
  echo "$(date +"%Y-%m-%d %H:%M:%S") speedtest binary not found" >> "$ERR_LOG"
  exit 1
fi

# jq needed for JSON parsing
if ! command -v jq >/dev/null 2>&1; then
  if [ ! -s "$CSV" ]; then
      echo "timestamp,download_mbps,upload_mbps,ping_ms,jitter_ms,packet_loss,server_name,server_id,isp,gw_ping_ms,gw_loss_pct,cf_ping_ms,cf_loss_pct,g_ping_ms,g_loss_pct,dns_ms,http_ms,wifi_iface,wifi_ssid,wifi_band,status,error" > "$CSV"
  fi
  TS="$(date +"%Y-%m-%d %H:%M:%S")"
  echo "$TS,,,,,,,,,,,,,,,,fail,\"jq missing (sudo apt install -y jq)\"" >> "$CSV"
  echo "$TS jq not installed" >> "$ERR_LOG"
  exit 1
fi

# Ensure CSV header
if [ ! -s "$CSV" ]; then
    echo "timestamp,download_mbps,upload_mbps,ping_ms,jitter_ms,packet_loss,server_name,server_id,isp,gw_ping_ms,gw_loss_pct,cf_ping_ms,cf_loss_pct,g_ping_ms,g_loss_pct,dns_ms,http_ms,wifi_iface,wifi_ssid,wifi_band,status,error" > "$CSV"
fi

############################
# HELPERS
############################
# --- Wi-Fi context (iface/ssid/band) ---
# DEPRECATED: Context is now determined per-interface in the main loop.

ts() { date +"%Y-%m-%d %H:%M:%S"; }

gw_ip() {
  ip route 2>/dev/null | awk '/^default/ {print $3; exit}'
}

# returns "avg_ms,loss_pct"; if no reply, avg empty, loss=100
ping_stats() {
  local target="$1" count="${2:-5}" opts="${3:-}" out avg loss
  # shellcheck disable=SC2086
  out=$(ping $opts -n -c "$count" -w $((count+1)) "$target" 2>/dev/null || true)
  avg=$(echo "$out"  | awk -F'/' '/^(rtt|round-trip)/ {print $5}')
  loss=$(echo "$out" | awk -F', *' '/packets transmitted/ {gsub(/%/,"",$3); print $3}')
  [ -z "${avg:-}" ] && avg=""
  [ -z "${loss:-}" ] && loss="100"
  echo "${avg:-},${loss:-100}"
}

dns_time_ms() {
  local ms
  ms=$(dig +tries=1 +timeout=2 "$DNS_TARGET" @1.1.1.1 2>/dev/null | awk '/Query time:/ {print $4; exit}')
  echo "${ms:-}"
}

http_time_ms() {
  local sec
  sec=$(curl -o /dev/null -s -w '%{time_total}' "$HTTP_URL" || echo "")
  if [ -n "$sec" ]; then awk -v s="$sec" 'BEGIN{printf "%.0f", s*1000}'; else echo ""; fi
}

run_speedtest_once() {
  local sid="$1"
  if [ -n "$sid" ]; then
    timeout "$CMD_TIMEOUT" "$BIN" --server-id "$sid" --accept-license --accept-gdpr --format=json --progress=no
  else
    timeout "$CMD_TIMEOUT" "$BIN" --accept-license --accept-gdpr --format=json --progress=no
  fi
}

write_ok_row() {
  local TS="$1" RESULT="$2" gw_avg="$3" gw_loss="$4" cf_avg="$5" cf_loss="$6" g_avg="$7" g_loss="$8" dns_ms="$9" http_ms="${10}"
  local safe_ts="${TS//[: ]/_}"
  echo "$RESULT" > "$RAW_DIR/${safe_ts}.json"

  local DL UL PING JITTER LOSS SNAME SID ISP
  DL=$(echo "$RESULT" | jq -r '.download.bandwidth // 0' | awk '{printf "%.3f", $1/125000}')
  UL=$(echo "$RESULT" | jq -r '.upload.bandwidth   // 0' | awk '{printf "%.3f", $1/125000}')
  PING=$(echo "$RESULT"   | jq -r '.ping.latency   // 0')
  JITTER=$(echo "$RESULT" | jq -r '.ping.jitter    // 0')
  LOSS=$(echo "$RESULT"   | jq -r '.packetLoss     // 0')
  SNAME=$(echo "$RESULT"  | jq -r '.server.name    // "unknown"' | tr ',' ';')
  SID=$(echo "$RESULT"    | jq -r '.server.id      // "unknown"')
  ISP=$(echo "$RESULT"    | jq -r '.isp           // "unknown"' | tr ',' ';')

  # 21 commas = 22 fields
  echo "$TS,$DL,$UL,$PING,$JITTER,$LOSS,\"$SNAME\",$SID,\"$ISP\",${gw_avg:-},${gw_loss:-},${cf_avg:-},${cf_loss:-},${g_avg:-},${g_loss:-},${dns_ms:-},${http_ms:-},$WIFI_IFACE,\"$WIFI_SSID\",$WIFI_BAND,ok," >> "$CSV"
}

write_fail_row() {
  local TS="$1" MSG="$2" gw_avg="$3" gw_loss="$4" cf_avg="$5" cf_loss="$6" g_avg="$7" g_loss="$8" dns_ms="$9" http_ms="${10}"
  local ERR
  ERR=$(echo "$MSG" | tr '\n' ' ' | sed 's/,/;/g' | cut -c1-240)
  # 21 commas: 1:TS, 2-9:empty, 10-15:pings, 16-17:telemetry, 18-20:wifi, 21:fail, 22:error
  echo "$TS,,,,,,,,,${gw_avg:-},${gw_loss:-},${cf_avg:-},${cf_loss:-},${g_avg:-},${g_loss:-},${dns_ms:-},${http_ms:-},$WIFI_IFACE,\"$WIFI_SSID\",$WIFI_BAND,fail,\"$ERR\"" >> "$CSV"
}

discover_servers() {
  # Parse first column (ID) after the "====" divider; take top SERVER_LIMIT
  # Handles leading spaces; prints only numeric IDs
  mapfile -t SERVERS < <(
    "$BIN" -L --accept-license --accept-gdpr 2>/dev/null | awk '
      /^=+/ {start=1; next}
      start && /^[[:space:]]*[0-9]+/ {
        gsub(/^[[:space:]]+/, "", $1);
        print $1
      }
    ' | head -n "$SERVER_LIMIT"
  )
}

############################
# MAIN (with flock)
############################
exec 9>"$LOCK"
flock -n 9 || exit 0

TSNOW="$(ts)"

# --- Interface Discovery ---
# We look for physical-looking interfaces that are UP and have an IP (excluding loopback)
# Common prefixes: eth, en (ethernet), wlan, wl (wifi)
mapfile -t RAW_INTERFACES < <(ip -br addr show | awk '$2=="UP" && $1 !~ /^lo/ && $1 !~ /^docker/ && $1 !~ /^veth/ {print $1}')

INTERFACES=()
for iface in "${RAW_INTERFACES[@]}"; do
  # Strip '@if...' suffix common in Docker bridge networking
  clean_iface="${iface%@*}"
  
  # Basic connectivity check: Can we reach a known public IP via this interface?
  # This filters out internal-only or problematic interfaces that cause binding errors.
  if ping -I "$clean_iface" -c 1 -w 2 8.8.8.8 >/dev/null 2>&1; then
    INTERFACES+=("$clean_iface")
  else
    echo "$(ts) Skipping $clean_iface (No route to 8.8.8.8)" >> "$ERR_LOG"
  fi
done

if [ ${#INTERFACES[@]} -le 1 ]; then
  # If 0 or 1 interface, run in default mode (no specific interface binding)
  # This is safest for single-NIC setups and Docker Desktop.
  INTERFACES=("default")
fi

for IFACE in "${INTERFACES[@]}"; do
  # --- Context for this interface ---
  WIFI_IFACE="$IFACE"
  WIFI_SSID="none"
  WIFI_BAND="none"

  # Initial set for default or non-detected interfaces
  if [ "$IFACE" = "default" ] || [ "$IFACE" = "eth0" ]; then
    WIFI_SSID="Wired"
    WIFI_BAND="Ethernet"
  fi

  if [ "$IFACE" != "default" ]; then
    # Try to determine if it's wifi
    if command -v iwgetid >/dev/null 2>&1 && iwgetid "$IFACE" >/dev/null 2>&1; then
      WIFI_SSID=$(iwgetid -r "$IFACE" 2>/dev/null || echo "unknown")
      # Determine band
      line=$(iwconfig "$IFACE" 2>/dev/null | awk '/IEEE 802.11/{print; exit}')
      freq=$(echo "$line" | sed -n 's/.*Frequency=\([0-9\.]\+\).*/\1/p')
      if [ -n "$freq" ]; then
        if awk "BEGIN{exit !($freq >= 4.0)}"; then WIFI_BAND="5 GHz"; else WIFI_BAND="2.4 GHz"; fi
      fi
    else
      # Check if it's ethernet/wired
      WIFI_SSID="Wired"
      WIFI_BAND="Ethernet"
    fi
  fi

  # ICMP/DNS/HTTP telemetry (interface-specific if possible)
  GW="$(ip route show dev "$IFACE" 2>/dev/null | awk '/default/ {print $3; exit}')"
  [ -z "$GW" ] && GW=$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')
  
  # For pings, we try to bind to the interface
  PING_OPTS=""
  [ "$IFACE" != "default" ] && PING_OPTS="-I $IFACE"
  
  IFS=',' read -r GW_AVG GW_LOSS <<< "$(ping_stats "${GW:-127.0.0.1}" 5 "$PING_OPTS")"
  IFS=',' read -r CF_AVG CF_LOSS <<< "$(ping_stats 1.1.1.1 5 "$PING_OPTS")"
  IFS=',' read -r G_AVG  G_LOSS  <<< "$(ping_stats 8.8.8.8 5 "$PING_OPTS")"
  
  # Dig doesn't easily bind to an interface name, but curl can
  DNS_MS="$(dns_time_ms)"
  HTTP_MS=""
  if [ "$IFACE" != "default" ]; then
    HTTP_MS=$(curl --interface "$IFACE" -o /dev/null -s -w '%{time_total}' "$HTTP_URL" || echo "")
    [ -n "$HTTP_MS" ] && HTTP_MS=$(awk -v s="$HTTP_MS" 'BEGIN{printf "%.0f", s*1000}')
  else
    HTTP_MS="$(http_time_ms)"
  fi

  # Build dynamic server list
  SERVERS=()
  discover_servers
  if [ ${#SERVERS[@]} -eq 0 ]; then
    SERVERS=("${STATIC_SERVERS[@]}")
  fi

  total_tries=0
  last_err=""
  SUCCESS=0

  for sid in "${SERVERS[@]}"; do
    for (( i=1; i<=TRIES_PER_SERVER; i++ )); do
      total_tries=$((total_tries+1))
      
      # Run speedtest bound to interface
      cmd=("$BIN" "--accept-license" "--accept-gdpr" "--format=json" "--progress=no")
      [ -n "$sid" ] && cmd+=("--server-id" "$sid")
      [ "$IFACE" != "default" ] && cmd+=("--interface" "$IFACE")
      
      result=$(timeout "$CMD_TIMEOUT" "${cmd[@]}" 2>&1); rc=$?
      
      if [ $rc -eq 0 ] && echo "$result" | jq -e . >/dev/null 2>&1; then
        write_ok_row "$TSNOW" "$result" "$GW_AVG" "$GW_LOSS" "$CF_AVG" "$CF_LOSS" "$G_AVG" "$G_LOSS" "$DNS_MS" "$HTTP_MS"
        SUCCESS=1
        break 2
      else
        short_err="$(echo "$result" | tr '\n' ' ' | cut -c1-240)"
        echo "$TSNOW iface=$IFACE sid=$sid try=$i rc=$rc err=$short_err" >> "$ERR_LOG"
        last_err="$short_err"
        sleep $((BACKOFF_BASE * i))
      fi
      [ $total_tries -ge $GLOBAL_MAX_TRIES ] && break 2
    done
  done

  if [ $SUCCESS -eq 0 ]; then
    write_fail_row "$TSNOW" "$last_err" "$GW_AVG" "$GW_LOSS" "$CF_AVG" "$CF_LOSS" "$G_AVG" "$G_LOSS" "$DNS_MS" "$HTTP_MS"
  fi
done

exit 0

