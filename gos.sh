#!/usr/bin/env bash
set -euo pipefail

GOS_VERSION="1.0.0"
GOS_INSTALL_DIR="${GOS_INSTALL_DIR:-/usr/local/go}"

# ─── Helpers ──────────────────────────────────────────────────────────────────

_gos_os() {
  case "$(uname -s)" in
    Darwin) echo "darwin" ;;
    Linux)  echo "linux"  ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *) echo "unsupported" ;;
  esac
}

_gos_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    arm64|aarch64) echo "arm64" ;;
    armv6l) echo "armv6l" ;;
    i386|i686) echo "386" ;;
    *) echo "unsupported" ;;
  esac
}

_gos_ext() {
  [ "$(_gos_os)" = "windows" ] && echo "zip" || echo "tar.gz"
}

# Validate version string to prevent path traversal and URL injection.
# Accepts: 1.22, 1.22.0, 1.23rc1, 1.23beta2
_gos_validate_version() {
  local version="$1"
  if ! echo "$version" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?(rc[0-9]+|beta[0-9]+)?$'; then
    echo "Error: invalid version format '${version}'." >&2
    echo "Expected format: X.Y[.Z][rcN|betaN]  e.g. 1.22.0, 1.23rc1" >&2
    return 1
  fi
}

# Guard against catastrophic rm -rf on dangerous paths.
_gos_validate_install_dir() {
  local dir="$1"
  # Reject empty
  if [ -z "$dir" ]; then
    echo "Error: GOS_INSTALL_DIR is empty." >&2
    return 1
  fi
  # Reject known system-critical roots
  case "$dir" in
    /|/usr|/etc|/home|/var|/bin|/sbin|/lib|/opt|/tmp|/root|/sys|/proc|/dev)
      echo "Error: GOS_INSTALL_DIR='${dir}' is a system-critical path. Refusing." >&2
      return 1
      ;;
  esac
  # Require at least 2 path components (e.g. /usr/local/go, not /go)
  local depth
  depth=$(echo "$dir" | tr -cd '/' | wc -c | tr -d ' ')
  if [ "$depth" -lt 2 ]; then
    echo "Error: GOS_INSTALL_DIR='${dir}' is too shallow. Use a path like /usr/local/go." >&2
    return 1
  fi
  # Require basename to contain "go" to prevent accidental misconfiguration
  local base
  base=$(basename "$dir")
  case "$base" in
    *go*) ;;
    *)
      echo "Error: GOS_INSTALL_DIR basename '${base}' does not contain 'go'. Refusing." >&2
      return 1
      ;;
  esac
}

# Download a URL to a file. Supports curl and wget.
_gos_download() {
  local url="$1" output="$2"
  if command -v curl &>/dev/null; then
    curl -fsSL -o "$output" "$url"
  elif command -v wget &>/dev/null; then
    wget -qO "$output" "$url"
  else
    echo "Error: neither curl nor wget found. Install one and try again."
    return 1
  fi
}

# Download a URL to stdout. Supports curl and wget.
_gos_download_stdout() {
  local url="$1"
  if command -v curl &>/dev/null; then
    curl -fsSL "$url"
  elif command -v wget &>/dev/null; then
    wget -qO- "$url"
  else
    echo "Error: neither curl nor wget found. Install one and try again." >&2
    return 1
  fi
}

_gos_fetch_latest() {
  local json
  json=$(_gos_download_stdout 'https://go.dev/dl/?mode=json')

  if command -v jq &>/dev/null; then
    echo "$json" | jq -r '.[0].version' | sed 's/^go//'
  else
    echo "$json" \
      | grep -o '"version": *"go[0-9.]*"' \
      | head -1 \
      | grep -o '[0-9][0-9.]*'
  fi
}

# Compute SHA256 checksum (cross-platform: Linux has sha256sum, macOS has shasum)
_gos_sha256() {
  local file="$1"
  if command -v sha256sum &>/dev/null; then
    sha256sum "$file" | cut -d' ' -f1
  elif command -v shasum &>/dev/null; then
    shasum -a 256 "$file" | cut -d' ' -f1
  else
    echo ""
  fi
}

# Fetch expected SHA256 for a package filename from Go API (requires jq)
_gos_fetch_checksum() {
  local pkg="$1"
  if ! command -v jq &>/dev/null; then
    echo "Warning: jq not found, cannot fetch checksum for verification." >&2
    echo ""
    return 0
  fi
  _gos_download_stdout 'https://go.dev/dl/?mode=json' \
    | jq -r --arg pkg "$pkg" '.[].files[] | select(.filename == $pkg) | .sha256'
}

_gos_current() {
  if command -v go &>/dev/null; then
    go version | grep -o 'go[0-9][0-9.]*' | head -1 | sed 's/go//'
  else
    echo "none"
  fi
}

# Determine if sudo is needed for GOS_INSTALL_DIR
_gos_needs_sudo() {
  # Never use sudo on Windows
  if [ "$(_gos_os)" = "windows" ]; then
    return 1
  fi
  # If install dir exists and is writable, no sudo
  if [ -d "$GOS_INSTALL_DIR" ] && [ -w "$GOS_INSTALL_DIR" ]; then
    return 1
  fi
  # If parent dir is writable, no sudo
  local parent
  parent=$(dirname "$GOS_INSTALL_DIR")
  if [ -w "$parent" ]; then
    return 1
  fi
  return 0
}

# Run a command with sudo only if needed
_gos_sudo() {
  if _gos_needs_sudo; then
    sudo "$@"
  else
    "$@"
  fi
}

_gos_remove_old() {
  if [ ! -d "$GOS_INSTALL_DIR" ]; then
    return 0
  fi

  if [ "$(_gos_os)" = "windows" ]; then
    cmd.exe /c "rmdir /s /q $(cygpath -w "$GOS_INSTALL_DIR")" 2>/dev/null || rm -rf "$GOS_INSTALL_DIR"
  else
    _gos_sudo rm -rf "$GOS_INSTALL_DIR"
  fi
}

_gos_install_version() {
  local version=$1
  local os arch ext pkg url tmp_dir tmp_file

  _gos_validate_version "$version" || return 1

  os=$(_gos_os)
  arch=$(_gos_arch)
  ext=$(_gos_ext)

  if [ "$os" = "unsupported" ] || [ "$arch" = "unsupported" ]; then
    echo "Error: unsupported OS or architecture: $os/$arch"
    return 1
  fi

  pkg="go${version}.${os}-${arch}.${ext}"
  url="https://go.dev/dl/${pkg}"

  # Use a unique temp directory to prevent symlink/TOCTOU attacks
  tmp_dir=$(mktemp -d) || { echo "Error: failed to create temp directory." >&2; return 1; }
  tmp_file="${tmp_dir}/${pkg}"

  echo "Downloading ${pkg}..."
  _gos_download "$url" "$tmp_file" || {
    echo "Error: download failed. Version '${version}' may not exist."
    rm -rf "$tmp_dir"
    return 1
  }

  # Verify checksum if tools are available
  local expected_sha actual_sha
  expected_sha=$(_gos_fetch_checksum "$pkg")
  if [ -n "$expected_sha" ]; then
    actual_sha=$(_gos_sha256 "$tmp_file")
    if [ -n "$actual_sha" ] && [ "$actual_sha" != "$expected_sha" ]; then
      echo "Error: checksum mismatch! Expected ${expected_sha}, got ${actual_sha}."
      echo "The download may be corrupted. Aborting."
      rm -rf "$tmp_dir"
      return 1
    fi
    echo "Checksum verified."
  else
    echo "Warning: skipping integrity verification (install jq for checksum support)." >&2
  fi

  echo "Removing old Go installation..."
  _gos_remove_old

  echo "Extracting..."
  local install_parent
  install_parent=$(dirname "$GOS_INSTALL_DIR")
  if [ "$ext" = "zip" ]; then
    if command -v unzip &>/dev/null; then
      unzip -q "$tmp_file" -d "$install_parent"
    elif command -v powershell.exe &>/dev/null; then
      powershell.exe -Command \
        "Expand-Archive -Path '$(cygpath -w "$tmp_file")' -DestinationPath '$(cygpath -w "$install_parent")' -Force"
    elif command -v tar &>/dev/null; then
      # Windows 10+ ships with tar that can handle zip
      tar -xf "$tmp_file" -C "$install_parent"
    else
      echo "Error: no extraction tool found (unzip, powershell, or tar)."
      rm -rf "$tmp_dir"
      return 1
    fi
  else
    _gos_sudo tar -C "$install_parent" -xzf "$tmp_file"
  fi

  rm -rf "$tmp_dir"
  echo "Done! $(go version)"
}

# ─── Commands ─────────────────────────────────────────────────────────────────

cmd_latest() {
  echo "Fetching latest stable Go version..."
  local latest current

  latest=$(_gos_fetch_latest)
  if [ -z "$latest" ]; then
    echo "Error: could not fetch latest version. Check your internet connection."
    return 1
  fi

  current=$(_gos_current)
  echo "Latest: go${latest}"

  if [ "$current" = "$latest" ]; then
    echo "Already on Go ${latest}, nothing to do."
    return 0
  fi

  echo "Current: go${current} -> go${latest}"
  _gos_install_version "$latest"
}

cmd_install() {
  local version=$1
  if [ -z "$version" ]; then
    echo "Usage: gos install <version>  e.g. gos install 1.26.1"
    return 1
  fi

  # Strip leading 'go' prefix if provided e.g. go1.26.1 -> 1.26.1
  version="${version#go}"

  _gos_validate_version "$version" || return 1

  local current
  current=$(_gos_current)
  if [ "$current" = "$version" ]; then
    echo "Already on Go ${version}, nothing to do."
    return 0
  fi

  _gos_install_version "$version"
}

cmd_current() {
  local current
  current=$(_gos_current)
  if [ "$current" = "none" ]; then
    echo "No Go installation found."
  else
    echo "go${current}"
  fi
}

cmd_list() {
  echo "Fetching available Go versions..."
  local json
  json=$(_gos_download_stdout 'https://go.dev/dl/?mode=json&include=all')

  if command -v jq &>/dev/null; then
    echo "$json" \
      | jq -r '.[].version' \
      | sed 's/^go//' \
      | sort -t. -k1,1n -k2,2n -k3,3n \
      | uniq \
      | sed 's/^/go/'
  else
    echo "$json" \
      | grep -o '"version": *"go[0-9.]*"' \
      | grep -o 'go[0-9][0-9.]*' \
      | sed 's/^go//' \
      | sort -t. -k1,1n -k2,2n -k3,3n \
      | uniq \
      | sed 's/^/go/'
  fi
}

cmd_version() {
  echo "gos v${GOS_VERSION}"
}

cmd_help() {
  cat <<EOF

gos — Go Switch v${GOS_VERSION}
Manage your Go installation with ease.

USAGE:
  gos <command> [options]

COMMANDS:
  latest              Install the latest stable Go version
  install <version>   Install a specific Go version (e.g. gos install 1.26.1)
  current             Show the currently active Go version
  list                List all available Go versions
  version             Show gos version
  help                Show this help message

EXAMPLES:
  gos latest
  gos install 1.24.0
  gos current
  gos list

EOF
}

# ─── Entrypoint ───────────────────────────────────────────────────────────────

main() {
  _gos_validate_install_dir "$GOS_INSTALL_DIR" || return 1

  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    latest)  cmd_latest ;;
    install) cmd_install "${1:-}" ;;
    current) cmd_current ;;
    list)    cmd_list ;;
    version) cmd_version ;;
    help|--help|-h) cmd_help ;;
    *)
      echo "Error: unknown command: $cmd"
      cmd_help
      return 1
      ;;
  esac
}

main "$@"
