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

# Download a URL to a file. HTTPS only, even across redirects.
# Supports curl and wget so the installer matches gos.sh's download tooling.
_download() {
  local url="$1" output="$2"
  if command -v curl &>/dev/null; then
    curl --proto '=https' --tlsv1.2 --connect-timeout 15 --retry 2 -fsSL -o "$output" "$url"
  elif command -v wget &>/dev/null; then
    wget --https-only --timeout=15 --tries=3 -qO "$output" "$url"
  else
    echo "Error: neither curl nor wget found. Install one and try again." >&2
    return 1
  fi
}

# "feed" is gos.sh's stricter variant; for the installer both values mean
# "fail closed when the download cannot be verified".
_require_checksum() {
  [ "${GOS_REQUIRE_CHECKSUM:-}" = "1" ] || [ "${GOS_REQUIRE_CHECKSUM:-}" = "feed" ]
}

# Verify integrity if a checksum is configured and tools are available.
# GOS_REQUIRE_CHECKSUM=1 turns every skipped verification into a hard failure.
_verify_checksum() {
  local file="$1" actual_sha

  if [ "$GOS_EXPECTED_SHA256" = "UPDATE_ON_RELEASE" ]; then
    if _require_checksum; then
      echo "Error: GOS_REQUIRE_CHECKSUM=1 but this installer is not release-pinned." >&2
      echo "Use the release asset instead:" >&2
      echo "  curl -fsSL https://github.com/johnny4young/gos/releases/latest/download/install.sh | bash" >&2
      return 1
    fi
    echo "Warning: no release checksum configured, skipping integrity check." >&2
    echo "         For a pinned, verified install use:" >&2
    echo "         curl -fsSL https://github.com/johnny4young/gos/releases/latest/download/install.sh | bash" >&2
    return 0
  fi

  actual_sha=$(_sha256 "$file")
  if [ -z "$actual_sha" ]; then
    if _require_checksum; then
      echo "Error: GOS_REQUIRE_CHECKSUM=1 but no SHA256 tool (sha256sum or shasum) was found." >&2
      return 1
    fi
    echo "Warning: no SHA256 tool found, skipping integrity check." >&2
    return 0
  fi

  if [ "$actual_sha" != "$GOS_EXPECTED_SHA256" ]; then
    echo "Error: checksum mismatch! Download may be corrupted or tampered with." >&2
    echo "  Expected: ${GOS_EXPECTED_SHA256}" >&2
    echo "  Got:      ${actual_sha}" >&2
    return 1
  fi

  echo "Checksum verified."
}

# Only use sudo if the target directory is not writable
_maybe_sudo() {
  if [ -w "$GOS_BIN_DIR" ]; then
    "$@"
    return
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    echo "Error: ${GOS_BIN_DIR} is not writable and sudo is unavailable." >&2
    echo "Re-run with GOS_BIN_DIR set to a writable directory, e.g.:" >&2
    echo "  curl -fsSL .../install.sh | GOS_BIN_DIR=\"\$HOME/.local/bin\" bash" >&2
    return 1
  fi

  sudo "$@"
}

_prepare_bin_dir() {
  if [ -d "$GOS_BIN_DIR" ]; then
    return 0
  fi

  if mkdir -p "$GOS_BIN_DIR" 2>/dev/null; then
    return 0
  fi

  if command -v sudo >/dev/null 2>&1 && sudo mkdir -p "$GOS_BIN_DIR"; then
    return 0
  fi

  echo "Error: failed to create GOS_BIN_DIR='${GOS_BIN_DIR}'." >&2
  echo "Create it manually or choose a writable install directory." >&2
  return 1
}

GOS_TMP_DIR=""

_cleanup_tmp() {
  if [ -n "$GOS_TMP_DIR" ] && [ -d "$GOS_TMP_DIR" ]; then
    rm -rf "$GOS_TMP_DIR"
  fi
}

main() {
  local tmp_dir tmp_file

  # Use a unique temp directory to prevent symlink/TOCTOU attacks; the trap
  # cleans it on every exit path, including interrupts.
  tmp_dir=$(mktemp -d) || {
    echo "Error: failed to create temp directory." >&2
    return 1
  }
  GOS_TMP_DIR="$tmp_dir"
  tmp_file="${tmp_dir}/gos"
  trap _cleanup_tmp EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  echo "Downloading gos..."
  _download "$GOS_SCRIPT_URL" "$tmp_file"

  _verify_checksum "$tmp_file"

  _prepare_bin_dir
  _maybe_sudo mv "$tmp_file" "$GOS_BIN_DIR/gos"
  _maybe_sudo chmod +x "$GOS_BIN_DIR/gos"
  echo "gos installed to ${GOS_BIN_DIR}/gos"
  echo "Run 'gos help' to get started."
}

# Everything is wrapped in main() so a partially downloaded script does nothing
# when piped to bash: execution starts only after the full file has parsed.
main "$@"
