#!/usr/bin/env bash
# Speedtest Dashboard Setup + Run Script
# -------------------------------------
# Creates venv, installs dependencies, loads .env config, and launches the app

set -e

# Move into this script's directory (for predictable relative paths)
cd "$(dirname "$0")" || {
  echo "❌ Unable to enter script directory"
  exit 1
}

# Load .env if present
if [ -f ".env" ]; then
  echo "⚙️  Loading environment variables from .env"
  export $(grep -v '^#' .env | xargs)
else
  echo "⚠️  No .env file found, using defaults"
fi

# Resolve CSV to absolute path based on current directory
CSV_PATH="$(realpath "$SPEEDTEST_CSV")"
export SPEEDTEST_CSV="$CSV_PATH"

echo "📄 Resolved CSV path: $SPEEDTEST_CSV"

# Create virtual environment if missing
if [ ! -d ".venv" ]; then
  echo "🧱 Creating virtual environment..."
  python3 -m venv .venv
fi

# Activate environment
source .venv/bin/activate

# Install dependencies
echo "📦 Installing dependencies..."
pip install --upgrade pip
pip install -r requirements.txt

# Launch app
echo "🌐 Launching dashboard on port ${DASH_PORT:-8050}..."
python streamlit_app.py