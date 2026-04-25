#!/usr/bin/env bash
set -euo pipefail

# NOTE: This installer downloads and runs code from GitHub over HTTPS.
# For maximum security, consider cloning the repo and verifying manually:
#   git clone https://github.com/johnny4young/gos.git
#   cp gos/gos.sh /usr/local/bin/gos && chmod +x /usr/local/bin/gos

GOS_BIN_DIR="${GOS_BIN_DIR:-/usr/local/bin}"

# These two values are patched by the release workflow when this script is
# shipped as a release asset. When unpatched (running from main), we fall back
# to fetching gos.sh from main without checksum verification.
GOS_RELEASE_TAG="UPDATE_ON_RELEASE"
GOS_EXPECTED_SHA256="UPDATE_ON_RELEASE"

if [ "$GOS_RELEASE_TAG" != "UPDATE_ON_RELEASE" ]; then
  GOS_SCRIPT_URL="https://github.com/johnny4young/gos/releases/download/${GOS_RELEASE_TAG}/gos.sh"
else
  GOS_SCRIPT_URL="https://raw.githubusercontent.com/johnny4young/gos/main/gos.sh"
fi

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

# Use a unique temp directory to prevent symlink/TOCTOU attacks
tmp_dir=$(mktemp -d) || { echo "Error: failed to create temp directory." >&2; exit 1; }
tmp_file="${tmp_dir}/gos"
trap 'rm -rf "$tmp_dir"' EXIT

echo "Downloading gos..."
# --proto =https forces TLS (no plaintext fallback even if a redirect tried it)
curl --proto '=https' --tlsv1.2 -fsSL "$GOS_SCRIPT_URL" -o "$tmp_file"

# Verify integrity if a checksum is configured and tools are available
if [ "$GOS_EXPECTED_SHA256" != "UPDATE_ON_RELEASE" ]; then
  actual_sha=$(_sha256 "$tmp_file")
  if [ -n "$actual_sha" ]; then
    if [ "$actual_sha" != "$GOS_EXPECTED_SHA256" ]; then
      echo "Error: checksum mismatch! Download may be corrupted or tampered with." >&2
      echo "  Expected: ${GOS_EXPECTED_SHA256}" >&2
      echo "  Got:      ${actual_sha}" >&2
      exit 1
    fi
    echo "Checksum verified."
  else
    echo "Warning: no SHA256 tool found, skipping integrity check." >&2
  fi
else
  echo "Warning: no release checksum configured, skipping integrity check." >&2
  echo "         For a pinned, verified install use:" >&2
  echo "         curl -fsSL https://github.com/johnny4young/gos/releases/latest/download/install.sh | bash" >&2
fi

# Only use sudo if the target directory is not writable
_maybe_sudo() {
  if [ -w "$GOS_BIN_DIR" ]; then
    "$@"
  else
    sudo "$@"
  fi
}

_maybe_sudo mv "$tmp_file" "$GOS_BIN_DIR/gos"
_maybe_sudo chmod +x "$GOS_BIN_DIR/gos"
echo "gos installed to ${GOS_BIN_DIR}/gos"
echo "Run 'gos help' to get started."
