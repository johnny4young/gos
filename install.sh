#!/usr/bin/env bash
set -euo pipefail

GOS_BIN_DIR="${GOS_BIN_DIR:-/usr/local/bin}"
GOS_SCRIPT_URL="https://raw.githubusercontent.com/johnny4young/gos/main/gos.sh"

echo "⬇️  Installing gos..."
curl -fsSL "$GOS_SCRIPT_URL" -o /tmp/gos
sudo mv /tmp/gos "$GOS_BIN_DIR/gos"
sudo chmod +x "$GOS_BIN_DIR/gos"
echo "✅ gos installed to ${GOS_BIN_DIR}/gos"
echo "   Run 'gos help' to get started."
