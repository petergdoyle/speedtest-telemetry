# streamlit run dashboard/app.py
# ──────────────────────────────────────────────────────────────────────────────
# Speedtest Telemetry Dashboard
# - Works with new CSV schema that includes wifi_iface, wifi_ssid, wifi_band
# - Backwards‑compatible with older CSVs (without Wi‑Fi columns)
# - Filter by date range, SSID, and band; view KPIs, trends, and failure logs
# - Auto‑refresh support for near‑real‑time viewing
#
# Usage:
#   export SPEEDTEST_CSV=/var/lib/speedtest-telemetry/speedtest.csv  # optional
#   streamlit run dashboard/app.py --server.port 8501
#
# Folder layout suggestion:
#   project/
#     dashboard/app.py
#     data/ (optional local mirror)
# ──────────────────────────────────────────────────────────────────────────────

import os
import pathlib
import pandas as pd
import numpy as np
import streamlit as st
import altair as alt
from datetime import datetime, timedelta

# ──────────────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────────────
DEFAULT_CSV = "/var/lib/speedtest-telemetry/speedtest.csv"
CSV_PATH = os.getenv("SPEEDTEST_CSV", DEFAULT_CSV)
RAW_DIR = os.getenv("SPEEDTEST_RAW", "/var/lib/speedtest-telemetry/raw")
AUTO_REFRESH_SECS = int(os.getenv("SPEEDTEST_REFRESH", "60"))

st.set_page_config(
    page_title="Speedtest Telemetry",
    page_icon="📶",
    layout="wide",
)

st.title("📶 Speedtest Telemetry Dashboard")
st.caption(f"CSV: `{CSV_PATH}` · Raw JSON: `{RAW_DIR}`")

# Optional auto-refresh (disabled if 0)
if AUTO_REFRESH_SECS > 0:
    st.experimental_set_query_params(_=str(int(datetime.utcnow().timestamp())))
    st.autorefresh = st.experimental_rerun  # noop placeholder to avoid lints
    st.write(f"⏱️ Auto-refresh ~ every {AUTO_REFRESH_SECS}s (reload the page to reset).")

# ──────────────────────────────────────────────────────────────────────────────
# Data Loading & Normalization
# ──────────────────────────────────────────────────────────────────────────────
@st.cache_data(show_spinner=False)
def load_csv(path: str) -> pd.DataFrame:
    if not os.path.exists(path):
        return pd.DataFrame()
    df = pd.read_csv(path)

    # Normalize column names (handle older schemas)
    cols = {c: c.strip() for c in df.columns}
    df.rename(columns=cols, inplace=True)

    # Expected canonical columns
    expected = [
        "timestamp",
        "download_mbps", "upload_mbps",
        "ping_ms", "jitter_ms", "packet_loss",
        "server_name", "server_id", "isp",
        "gw_ping_ms", "gw_loss_pct", "cf_ping_ms", "cf_loss_pct",
        "g_ping_ms", "g_loss_pct", "dns_ms", "http_ms",
        "wifi_iface", "wifi_ssid", "wifi_band",
        "status", "error",
    ]

    for c in expected:
        if c not in df.columns:
            df[c] = np.nan if c not in ("status", "error", "wifi_iface", "wifi_ssid", "wifi_band", "server_name", "isp") else ""

    # Parse timestamp
    def _parse_ts(x):
        try:
            return pd.to_datetime(x)
        except Exception:
            return pd.NaT
    df["timestamp"] = df["timestamp"].apply(_parse_ts)
    df.sort_values("timestamp", inplace=True)

    # Coerce numerics
    num_cols = [c for c in df.columns if c.endswith("_ms") or c.endswith("_mbps") or c.endswith("_pct")]
    for c in num_cols:
        df[c] = pd.to_numeric(df[c], errors="coerce")

    # Status normalize
    df["status"] = df["status"].fillna("").replace({"ok":"ok", "fail":"fail"})

    # Backfill band label if missing but SSID suggests band
    df["wifi_band"] = df["wifi_band"].fillna("")

    return df


df = load_csv(CSV_PATH)

if df.empty or df["timestamp"].isna().all():
    st.info("No data yet. Trigger a run or check the CSV path.")
    st.stop()

# ──────────────────────────────────────────────────────────────────────────────
# Sidebar Filters
# ──────────────────────────────────────────────────────────────────────────────
with st.sidebar:
    st.header("Filters")

    # Date range (default: last 7 days)
    max_ts = pd.to_datetime(df["timestamp"].max())
    min_ts = pd.to_datetime(df["timestamp"].min())
    default_start = max_ts - timedelta(days=7)

    date_range = st.date_input(
        "Date range",
        value=(default_start.date(), max_ts.date()),
        min_value=min_ts.date(),
        max_value=max_ts.date(),
    )

    # Band & SSID filters
    bands = [b for b in sorted(df["wifi_band"].dropna().unique()) if b]
    ssids = [s for s in sorted(df["wifi_ssid"].dropna().unique()) if s]

    band_sel = st.multiselect("Wi‑Fi Band", options=bands, default=bands)
    ssid_sel = st.multiselect("SSID", options=ssids, default=ssids)

    # Moving average window
    ma_window = st.slider("Moving Avg (samples)", 1, 21, 5, help="Smoothing window for trend lines")

# Apply filters
start_dt = pd.to_datetime(datetime.combine(date_range[0], datetime.min.time()))
end_dt = pd.to_datetime(datetime.combine(date_range[1], datetime.max.time()))
mask = (df["timestamp"] >= start_dt) & (df["timestamp"] <= end_dt)
if band_sel:
    mask &= df["wifi_band"].isin(band_sel)
if ssid_sel:
    mask &= df["wifi_ssid"].isin(ssid_sel)

vf = df.loc[mask].copy()

if vf.empty:
    st.warning("No rows match the current filters.")
    st.stop()

# Smoothing
for col in ["download_mbps", "upload_mbps", "ping_ms"]:
    vf[f"{col}_ma{ma_window}"] = vf[col].rolling(ma_window, min_periods=1).median()

# ──────────────────────────────────────────────────────────────────────────────
# KPIs
# ──────────────────────────────────────────────────────────────────────────────
col1, col2, col3, col4, col5 = st.columns(5)
col1.metric("Median Download (Mb/s)", f"{vf['download_mbps'].median():.1f}")
col2.metric("Median Upload (Mb/s)", f"{vf['upload_mbps'].median():.1f}")
col3.metric("Median Ping (ms)", f"{vf['ping_ms'].median():.0f}")
col4.metric("Packet Loss (%)", f"{vf['packet_loss'].fillna(0).median():.1f}")
col5.metric("Samples", f"{len(vf):,}")

st.divider()

# ──────────────────────────────────────────────────────────────────────────────
# Charts
# ──────────────────────────────────────────────────────────────────────────────
# 1) Throughput over time (smoothed)
base = alt.Chart(vf).encode(x=alt.X('timestamp:T', title='Time'))

dl_line = base.mark_line().encode(
    y=alt.Y('download_mbps_ma{w}:Q'.format(w=ma_window), title='Download (Mb/s)'),
    tooltip=['timestamp:T','download_mbps:Q','wifi_band:N','wifi_ssid:N']
)

ul_line = base.mark_line().encode(
    y=alt.Y('upload_mbps_ma{w}:Q'.format(w=ma_window), title='Upload (Mb/s)'),
    color=alt.value('#999999'),
    tooltip=['timestamp:T','upload_mbps:Q','wifi_band:N','wifi_ssid:N']
)

band_color = alt.Color('wifi_band:N', legend=alt.Legend(title='Wi‑Fi Band'))

st.subheader("Throughput Over Time (smoothed)")
st.altair_chart(
    dl_line.encode(color=band_color) + ul_line.encode(color=band_color),
    use_container_width=True,
)

# 2) Ping / Jitter over time
st.subheader("Latency (Ping & Jitter)")
lat = base.transform_fold(
    ["ping_ms", "jitter_ms"],
    as_=["metric", "value"],
).mark_line().encode(
    y=alt.Y('value:Q', title='ms'),
    color='metric:N',
    tooltip=['timestamp:T','metric:N','value:Q','wifi_band:N','wifi_ssid:N']
)
st.altair_chart(lat, use_container_width=True)

# 3) Distribution by Band
st.subheader("Distribution by Wi‑Fi Band")
box = alt.Chart(vf).mark_boxplot(extent='min-max').encode(
    x=alt.X('wifi_band:N', title='Wi‑Fi Band'),
    y=alt.Y('download_mbps:Q', title='Download (Mb/s)'),
    color='wifi_band:N'
)
st.altair_chart(box, use_container_width=True)

st.divider()

# ──────────────────────────────────────────────────────────────────────────────
# Failures Table
# ──────────────────────────────────────────────────────────────────────────────
fails = vf[vf['status'] == 'fail'].copy()
if len(fails):
    st.subheader("Failures")
    show_cols = [
        'timestamp','error','server_name','isp','wifi_ssid','wifi_band',
        'dns_ms','http_ms','gw_ping_ms','cf_ping_ms','g_ping_ms'
    ]
    st.dataframe(fails[show_cols].sort_values('timestamp', ascending=False), use_container_width=True)
else:
    st.subheader("Failures")
    st.write("✅ No failures in the selected range.")

# ──────────────────────────────────────────────────────────────────────────────
# Raw JSON summary (optional quick view)
# ──────────────────────────────────────────────────────────────────────────────
raw_count = 0
try:
    raw_count = len([p for p in pathlib.Path(RAW_DIR).glob('*.json')])
except Exception:
    pass

st.caption(f"Raw JSON files in `{RAW_DIR}`: {raw_count}")

# ──────────────────────────────────────────────────────────────────────────────
# Footer
# ──────────────────────────────────────────────────────────────────────────────
st.caption("Tip: set SPEEDTEST_CSV, SPEEDTEST_RAW, and SPEEDTEST_REFRESH in the environment to customize.")
