#!/usr/bin/env bash
# Speedtest Dashboard Setup + Run Script
# -------------------------------------
# Uses project-level venv, loads config/env, and launches the Streamlit app.

set -euo pipefail

# Resolve project root (this script lives in $PROJECT_ROOT/dashboard)
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "📂 Project root: $PROJECT_ROOT"

# -------------------------------
# Load environment variables
# Priority: config.env (project root) > .env (project root) > inline defaults
# -------------------------------
if [ -f "$PROJECT_ROOT/config.env" ]; then
  echo "⚙️  Loading environment variables from config.env"
  # shellcheck disable=SC2046
  export $(grep -v '^#' "$PROJECT_ROOT/config.env" | xargs)
elif [ -f "$PROJECT_ROOT/.env" ]; then
  echo "⚙️  Loading environment variables from .env"
  # shellcheck disable=SC2046
  export $(grep -v '^#' "$PROJECT_ROOT/.env" | xargs)
else
  echo "⚠️  No config.env or .env found, using defaults"
fi

# Defaults if not provided by env/config
: "${SPEEDTEST_CSV:=/var/lib/speedtest-telemetry/speedtest.csv}"
: "${SPEEDTEST_RAW:=/var/lib/speedtest-telemetry/raw}"
: "${SPEEDTEST_REFRESH:=60}"
: "${DASH_PORT:=8501}"

# Resolve CSV path to absolute path
if command -v realpath >/dev/null 2>&1; then
  CSV_PATH="$(realpath "$SPEEDTEST_CSV" 2>/dev/null || echo "$SPEEDTEST_CSV")"
else
  # Fallback if realpath is missing
  CSV_PATH="$SPEEDTEST_CSV"
fi
export SPEEDTEST_CSV="$CSV_PATH"

echo "📄 Resolved CSV path: $SPEEDTEST_CSV"
echo "📁 SPEEDTEST_RAW:     $SPEEDTEST_RAW"
echo "⏱️  Refresh seconds:  $SPEEDTEST_REFRESH"
echo "🌐 Dashboard port:    $DASH_PORT"

# -------------------------------
# Activate project-level virtual environment
# -------------------------------
if [ ! -d "$PROJECT_ROOT/.venv" ]; then
  echo "🧱 Creating project virtual environment at $PROJECT_ROOT/.venv..."
  python3 -m venv "$PROJECT_ROOT/.venv"
fi

# shellcheck disable=SC1090
source "$PROJECT_ROOT/.venv/bin/activate"

# -------------------------------
# Install / update dependencies
# -------------------------------
if [ -f "$PROJECT_ROOT/requirements.txt" ]; then
  echo "📦 Installing dependencies from requirements.txt..."
  pip install --upgrade pip
  pip install -r "$PROJECT_ROOT/requirements.txt"
else
  echo "⚠️  No requirements.txt found at $PROJECT_ROOT/requirements.txt"
fi

# -------------------------------
# Launch Streamlit app
# -------------------------------
echo "🚀 Launching dashboard on port ${DASH_PORT}..."
exec streamlit run "$PROJECT_ROOT/dashboard/streamlit_app.py" --server.port "$DASH_PORT"