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

BASE_DIR="$HOME/speedtest-logs/data"
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
detect_wifi_context() {
  WIFI_IFACE="none"; WIFI_SSID="none"; WIFI_BAND="none"
  if command -v nmcli >/dev/null 2>&1; then
    # Active Wi-Fi interface
    local dev
    dev=$(nmcli -t -f DEVICE,TYPE,STATE device | awk -F: '$2=="wifi" && $3=="connected"{print $1; exit}')
    if [ -n "$dev" ]; then
      WIFI_IFACE="$dev"
      # SSID of the active connection for this device
      WIFI_SSID=$(nmcli -t -f DEVICE,CONNECTION device | awk -F: -v d="$dev" '$1==d{print $2; exit}')
      # Active frequency for this device
      local freq
      freq=$(nmcli -t -f ACTIVE,SSID,FREQ dev wifi list ifname "$dev" 2>/dev/null | awk -F: '$1=="yes"{print $3; exit}')
      # freq could be like "2412 MHz" or "5.2 GHz"; extract number (in MHz if present) else the GHz number
      if echo "$freq" | grep -qi 'ghz'; then
        # Extract numeric GHz
        val=$(echo "$freq" | awk '{print $1}' | sed 's/[^0-9\.]//g')
        if awk "BEGIN{exit !($val >= 3.0)}"; then WIFI_BAND="5 GHz"; else WIFI_BAND="2.4 GHz"; fi
      elif echo "$freq" | grep -qi 'mhz'; then
        mhz=$(echo "$freq" | sed 's/[^0-9]//g')
        if [ -n "$mhz" ] && [ "$mhz" -ge 3000 ]; then WIFI_BAND="5 GHz"; else WIFI_BAND="2.4 GHz"; fi
      fi
    fi
  else
    # Fallback to iw utilities if nmcli unavailable
    if command -v iwgetid >/dev/null 2>&1; then
      dev_guess=$(iwgetid -r 2>/dev/null)
      [ -n "$dev_guess" ] && WIFI_SSID="$dev_guess"
    fi
    if command -v iwconfig >/dev/null 2>&1; then
      line=$(iwconfig 2>/dev/null | awk '/IEEE 802.11/{print; exit}')
      if [ -n "$line" ]; then
        WIFI_IFACE=$(echo "$line" | awk '{print $1}')
        freq=$(echo "$line" | sed -n 's/.*Frequency=\([0-9\.]\+\).*/\1/p')
        if [ -n "$freq" ]; then
          if awk "BEGIN{exit !($freq >= 3.0)}"; then WIFI_BAND="5 GHz"; else WIFI_BAND="2.4 GHz"; fi
        fi
      fi
    fi
  fi
  # sanitize commas in SSID for CSV
  WIFI_SSID=${WIFI_SSID//,/;}
}

ts() { date +"%Y-%m-%d %H:%M:%S"; }

gw_ip() {
  ip route 2>/dev/null | awk '/^default/ {print $3; exit}'
}

# returns "avg_ms,loss_pct"; if no reply, avg empty, loss=100
ping_stats() {
  local target="$1" count="${2:-5}" out avg loss
  out=$(ping -n -c "$count" -w $((count+1)) "$target" 2>/dev/null || true)
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

  echo "$TS,$DL,$UL,$PING,$JITTER,$LOSS,$SNAME,$SID,$ISP,${gw_avg:-},${gw_loss:-},${cf_avg:-},${cf_loss:-},${g_avg:-},${g_loss:-},${dns_ms:-},${http_ms:-},$WIFI_IFACE,$WIFI_SSID,$WIFI_BAND,ok," >> "$CSV"
}

write_fail_row() {
  local TS="$1" MSG="$2" gw_avg="$3" gw_loss="$4" cf_avg="$5" cf_loss="$6" g_avg="$7" g_loss="$8" dns_ms="$9" http_ms="${10}"
  local ERR
  ERR=$(echo "$MSG" | tr '\n' ' ' | sed 's/,/;/g' | cut -c1-240)
  echo "$TS,,,,,,, ,${gw_avg:-},${gw_loss:-},${cf_avg:-},${cf_loss:-},${g_avg:-},${g_loss:-},${dns_ms:-},${http_ms:-},$WIFI_IFACE,$WIFI_SSID,$WIFI_BAND,fail,\"$ERR\"" >> "$CSV"
}

discover_servers() {
  # Parse first column (ID) after the "====" divider; take top SERVER_LIMIT
  # Handles leading spaces; prints only numeric IDs
  mapfile -t SERVERS < <(
    "$BIN" -L 2>/dev/null | awk '
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
# Detect Wi-Fi context for this run
detect_wifi_context


# ICMP/DNS/HTTP telemetry first (so we still log even if speedtest fails)
GW="$(gw_ip)"
read -r GW_AVG GW_LOSS <<< "$(ping_stats "${GW:-127.0.0.1}")"
read -r CF_AVG CF_LOSS <<< "$(ping_stats 1.1.1.1)"
read -r G_AVG  G_LOSS  <<< "$(ping_stats 8.8.8.8)"
DNS_MS="$(dns_time_ms)"
HTTP_MS="$(http_time_ms)"

# Build dynamic server list
SERVERS=()
discover_servers
if [ ${#SERVERS[@]} -eq 0 ]; then
  # fallback to static if discovery failed
  SERVERS=("${STATIC_SERVERS[@]}")
  echo "$TSNOW server discovery failed; using static list: ${SERVERS[*]}" >> "$ERR_LOG"
fi

total_tries=0
last_err=""

for sid in "${SERVERS[@]}"; do
  for (( i=1; i<=TRIES_PER_SERVER; i++ )); do
    total_tries=$((total_tries+1))
    result="$(run_speedtest_once "$sid" 2>&1)"; rc=$?
    if [ $rc -eq 0 ] && echo "$result" | jq -e . >/dev/null 2>&1; then
      write_ok_row "$TSNOW" "$result" "$GW_AVG" "$GW_LOSS" "$CF_AVG" "$CF_LOSS" "$G_AVG" "$G_LOSS" "$DNS_MS" "$HTTP_MS"
      exit 0
    else
      short_err="$(echo "$result" | tr '\n' ' ' | cut -c1-240)"
      echo "$TSNOW sid=$sid try=$i rc=$rc err=$short_err" >> "$ERR_LOG"
      last_err="$short_err"
      sleep $((BACKOFF_BASE * i))
    fi
    if [ $total_tries -ge $GLOBAL_MAX_TRIES ]; then
      write_fail_row "$TSNOW" "$last_err" "$GW_AVG" "$GW_LOSS" "$CF_AVG" "$CF_LOSS" "$G_AVG" "$G_LOSS" "$DNS_MS" "$HTTP_MS"
      exit 1
    fi
  done
done

# all failed
write_fail_row "$TSNOW" "$last_err" "$GW_AVG" "$GW_LOSS" "$CF_AVG" "$CF_LOSS" "$G_AVG" "$G_LOSS" "$DNS_MS" "$HTTP_MS"
exit 1

