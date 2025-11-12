import os
import time
import pandas as pd
from datetime import datetime, timedelta

from dotenv import load_dotenv
from dash import Dash, html, dcc, Input, Output, dash_table
import plotly.graph_objects as go

# --- Config ---
load_dotenv()
CSV_PATH = os.getenv("SPEEDTEST_CSV", os.path.expanduser("~/speedtest-logs/data/speedtest.csv"))
PORT = int(os.getenv("DASH_PORT", "8050"))

REFRESH_MS = 30_000  # auto-refresh every 30s

# columns expected in CSV
EXPECTED = [
    "timestamp","download_mbps","upload_mbps","ping_ms","jitter_ms","packet_loss",
    "server_name","server_id","isp",
    "gw_ping_ms","gw_loss_pct","cf_ping_ms","cf_loss_pct","g_ping_ms","g_loss_pct",
    "dns_ms","http_ms","status","error"
]

def load_data():
    if not os.path.exists(CSV_PATH):
        return pd.DataFrame(columns=EXPECTED)
    try:
        df = pd.read_csv(CSV_PATH)
    except Exception:
        return pd.DataFrame(columns=EXPECTED)
    # coerce dtypes
    if "timestamp" in df.columns:
        df["timestamp"] = pd.to_datetime(df["timestamp"], errors="coerce")
    # ensure numeric where possible
    for c in ["download_mbps","upload_mbps","ping_ms","jitter_ms","packet_loss",
              "gw_ping_ms","gw_loss_pct","cf_ping_ms","cf_loss_pct","g_ping_ms","g_loss_pct",
              "dns_ms","http_ms","server_id"]:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")
    # sort by time
    if "timestamp" in df.columns:
        df = df.sort_values("timestamp")
    return df

app = Dash(__name__)
server = app.server

def layout():
    df = load_data()

    # defaults for date filter
    now = pd.Timestamp.utcnow()
    min_ts = df["timestamp"].min() if "timestamp" in df and not df.empty else now - pd.Timedelta(days=1)
    max_ts = df["timestamp"].max() if "timestamp" in df and not df.empty else now
    start_default = (max_ts - pd.Timedelta(hours=12)).to_pydatetime() if pd.notna(max_ts) else (now - pd.Timedelta(hours=12)).to_pydatetime()
    end_default = max_ts.to_pydatetime() if pd.notna(max_ts) else now.to_pydatetime()

    return html.Div(style={"fontFamily":"Inter, system-ui, -apple-system, Segoe UI, Roboto, Arial", "padding":"16px"}, children=[
        html.H2("Speedtest Telemetry Dashboard", style={"margin":"0 0 8px 0"}),
        html.Div(f"CSV: {CSV_PATH}", style={"color":"#666","fontSize":"12px","marginBottom":"8px"}),

        html.Div(style={"display":"flex","gap":"12px","flexWrap":"wrap","alignItems":"center","marginBottom":"8px"}, children=[
            html.Div([
                html.Label("Date range"),
                dcc.DatePickerRange(
                    id="date-range",
                    min_date_allowed=min_ts.to_pydatetime() if pd.notna(min_ts) else (datetime.utcnow()-timedelta(days=30)),
                    max_date_allowed=datetime.utcnow()+timedelta(days=1),
                    start_date=start_default.date(),
                    end_date=end_default.date(),
                    display_format="YYYY-MM-DD",
                )
            ]),
            html.Div([
                html.Label("Hours back"),
                dcc.Dropdown(
                    id="hours-back",
                    options=[{"label": l, "value": v} for l,v in [
                        ("All (ignore)", 0),
                        ("3h", 3),
                        ("6h", 6),
                        ("12h", 12),
                        ("24h", 24),
                        ("48h", 48),
                        ("7d", 24*7),
                    ]],
                    value=12, clearable=False, style={"width":"140px"}
                )
            ]),
            html.Div(id="latest-card", style={
                "padding":"8px 12px","border":"1px solid #ddd","borderRadius":"10px","background":"#fafafa"
            })
        ]),

        dcc.Graph(id="throughput-graph"),
        dcc.Graph(id="latency-graph"),
        dcc.Graph(id="loss-graph"),

        html.H4("Recent Samples"),
        dash_table.DataTable(
            id="recent-table",
            columns=[{"name": c, "id": c} for c in ["timestamp","download_mbps","upload_mbps","ping_ms","jitter_ms","packet_loss","server_name","status","error"] if c in df.columns],
            page_size=10,
            style_cell={"fontFamily":"inherit","fontSize":"13px","padding":"6px"},
            style_header={"fontWeight":"600"},
            style_table={"overflowX":"auto"},
        ),

        # auto refresh
        dcc.Interval(id="interval", interval=REFRESH_MS, n_intervals=0),
    ])

app.layout = layout

def filter_df(df, start_date, end_date, hours_back):
    if df.empty:
        return df
    out = df.copy()
    if hours_back and int(hours_back) > 0 and "timestamp" in out:
        cutoff = pd.Timestamp.utcnow() - pd.Timedelta(hours=int(hours_back))
        out = out[out["timestamp"] >= cutoff]
    else:
        # use datepicker
        if start_date:
            out = out[out["timestamp"] >= pd.to_datetime(start_date)]
        if end_date:
            out = out[out["timestamp"] <= pd.to_datetime(end_date) + pd.Timedelta(days=1)]
    return out

@app.callback(
    Output("throughput-graph","figure"),
    Output("latency-graph","figure"),
    Output("loss-graph","figure"),
    Output("recent-table","data"),
    Output("latest-card","children"),
    Input("interval","n_intervals"),
    Input("date-range","start_date"),
    Input("date-range","end_date"),
    Input("hours-back","value"),
)
def update_graphs(_, start_date, end_date, hours_back):
    df = load_data()
    dff = filter_df(df, start_date, end_date, hours_back)

    # Latest card
    if not dff.empty:
        last = dff.iloc[-1]
        latest = html.Span([
            html.B("Latest: "), 
            f"{last.get('timestamp','')}  ",
            f"↓ {last.get('download_mbps', float('nan')):.1f} Mbps, ",
            f"↑ {last.get('upload_mbps', float('nan')):.1f} Mbps, ",
            f"ping {last.get('ping_ms', float('nan')):.0f} ms, ",
            f"loss {(last.get('packet_loss', 0.0)):.1f}%, ",
            f"{last.get('server_name','')}"
        ])
    else:
        latest = "No data yet."

    # Throughput figure
    fig_tp = go.Figure()
    if not dff.empty:
        fig_tp.add_trace(go.Scatter(x=dff["timestamp"], y=dff["download_mbps"], name="Download (Mbps)", mode="lines+markers"))
        fig_tp.add_trace(go.Scatter(x=dff["timestamp"], y=dff["upload_mbps"], name="Upload (Mbps)", mode="lines+markers"))
        # rolling average
        if len(dff) >= 3:
            fig_tp.add_trace(go.Scatter(x=dff["timestamp"], y=dff["download_mbps"].rolling(3).mean(), name="↓ 3-pt avg", mode="lines"))
            fig_tp.add_trace(go.Scatter(x=dff["timestamp"], y=dff["upload_mbps"].rolling(3).mean(), name="↑ 3-pt avg", mode="lines"))
    fig_tp.update_layout(title="Throughput", xaxis_title="Time", yaxis_title="Mbps", legend_title="", hovermode="x unified")

    # Latency/Jitter
    fig_lat = go.Figure()
    if not dff.empty:
        fig_lat.add_trace(go.Scatter(x=dff["timestamp"], y=dff["ping_ms"], name="Ping (ms)", mode="lines+markers"))
        if "jitter_ms" in dff:
            fig_lat.add_trace(go.Scatter(x=dff["timestamp"], y=dff["jitter_ms"], name="Jitter (ms)", mode="lines+markers"))
        # Optional: external ICMP
        for label, col in [("GW ping","gw_ping_ms"),("1.1.1.1","cf_ping_ms"),("8.8.8.8","g_ping_ms")]:
            if col in dff:
                fig_lat.add_trace(go.Scatter(x=dff["timestamp"], y=dff[col], name=label, mode="lines"))
    fig_lat.update_layout(title="Latency / Jitter", xaxis_title="Time", yaxis_title="ms", hovermode="x unified")

    # Packet loss
    fig_loss = go.Figure()
    if not dff.empty:
        fig_loss.add_trace(go.Scatter(x=dff["timestamp"], y=dff["packet_loss"], name="Speedtest loss (%)", mode="lines+markers"))
        for label, col in [("GW loss %","gw_loss_pct"),("1.1.1.1 loss %","cf_loss_pct"),("8.8.8.8 loss %","g_loss_pct")]:
            if col in dff:
                fig_loss.add_trace(go.Scatter(x=dff["timestamp"], y=dff[col], name=label, mode="lines"))
    fig_loss.update_layout(title="Packet Loss", xaxis_title="Time", yaxis_title="%", hovermode="x unified")

    # Recent table
    table_cols = [c for c in ["timestamp","download_mbps","upload_mbps","ping_ms","jitter_ms","packet_loss","server_name","status","error"] if c in dff.columns]
    recent_rows = dff.tail(25)[table_cols].iloc[::-1].to_dict("records") if not dff.empty else []

    return fig_tp, fig_lat, fig_loss, recent_rows, latest

if __name__ == "__main__":
    app.run_server(host="0.0.0.0", port=PORT, debug=False)