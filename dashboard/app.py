import os
import time
import pandas as pd
from dash import Dash, dcc, html
import plotly.express as px

DATA_CSV = os.path.expanduser('~/speedtest-logs/data/speedtest.csv')

app = Dash(__name__, title="Speedtest Telemetry")

def load_df():
    if not os.path.exists(DATA_CSV):
        return pd.DataFrame()
    df = pd.read_csv(DATA_CSV)
    # coerce time
    if 'timestamp' in df.columns:
        df['timestamp'] = pd.to_datetime(df['timestamp'], errors='coerce')
    return df

app.layout = html.Div([
    html.H2("Speedtest Telemetry"),
    dcc.Interval(id='tick', interval=60_000, n_intervals=0),
    dcc.Graph(id='dl'),
    dcc.Graph(id='ul'),
    dcc.Graph(id='lat'),
    dcc.Graph(id='loss')
])

@app.callback(
    [dcc.Output('dl','figure'),
     dcc.Output('ul','figure'),
     dcc.Output('lat','figure'),
     dcc.Output('loss','figure')],
    [dcc.Input('tick','n_intervals')]
)
def update(_):
    df = load_df()
    if df.empty:
        return [px.scatter(title="No data yet")]*4

    dl = px.line(df, x='timestamp', y='download_mbps', title='Download (Mbps)')
    ul = px.line(df, x='timestamp', y='upload_mbps', title='Upload (Mbps)')
    lat = px.line(df, x='timestamp', y=['ping_ms','jitter_ms'], title='Latency/Jitter (ms)')
    loss = px.line(df, x='timestamp', y='packet_loss', title='Packet Loss (%)')
    return dl, ul, lat, loss

if __name__ == "__main__":
    app.run_server(host="0.0.0.0", port=8050, debug=False)

