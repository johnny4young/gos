#!/usr/bin/env bash
set -euo pipefail

# NOTE: This installer downloads and runs code from GitHub over HTTPS.
# For maximum security, consider cloning the repo and verifying manually:
#   git clone https://github.com/johnny4young/gos.git
#   cp gos/gos.sh /usr/local/bin/gos && chmod +x /usr/local/bin/gos

GOS_BIN_DIR="${GOS_BIN_DIR:-/usr/local/bin}"
GOS_SCRIPT_URL="https://raw.githubusercontent.com/johnny4young/gos/main/gos.sh"

# Expected SHA256 of gos.sh — update this on each release
GOS_EXPECTED_SHA256="UPDATE_ON_RELEASE"

# Cross-platform SHA256 helper
_sha256() {
  if command -v sha256sum &>/dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum &>/dev/null; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    echo ""
  fi
}

echo "Downloading gos..."
curl -fsSL "$GOS_SCRIPT_URL" -o /tmp/gos

# Verify integrity if a checksum is configured and tools are available
if [ "$GOS_EXPECTED_SHA256" != "UPDATE_ON_RELEASE" ]; then
  actual_sha=$(_sha256 /tmp/gos)
  if [ -n "$actual_sha" ]; then
    if [ "$actual_sha" != "$GOS_EXPECTED_SHA256" ]; then
      echo "Error: checksum mismatch! Download may be corrupted or tampered with." >&2
      echo "  Expected: ${GOS_EXPECTED_SHA256}" >&2
      echo "  Got:      ${actual_sha}" >&2
      rm -f /tmp/gos
      exit 1
    fi
    echo "Checksum verified."
  else
    echo "Warning: no SHA256 tool found, skipping integrity check." >&2
  fi
else
  echo "Warning: no release checksum configured, skipping integrity check." >&2
fi

# Only use sudo if the target directory is not writable
_maybe_sudo() {
  if [ -w "$GOS_BIN_DIR" ]; then
    "$@"
  else
    sudo "$@"
  fi
}

_maybe_sudo mv /tmp/gos "$GOS_BIN_DIR/gos"
_maybe_sudo chmod +x "$GOS_BIN_DIR/gos"
echo "gos installed to ${GOS_BIN_DIR}/gos"
echo "Run 'gos help' to get started."
