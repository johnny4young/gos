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

_gos_fetch_latest() {
  curl -s 'https://go.dev/dl/?mode=json' \
    | grep -o '"version": "go[0-9.]*"' \
    | head -1 \
    | grep -o '[0-9][0-9.]*'
}

_gos_current() {
  if command -v go &>/dev/null; then
    go version | grep -o 'go[0-9][0-9.]*' | head -1 | sed 's/go//'
  else
    echo "none"
  fi
}

_gos_remove_old() {
  local os
  os=$(_gos_os)

  if [ "$os" = "windows" ]; then
    if [ -d "$GOS_INSTALL_DIR" ]; then
      cmd.exe /c "rmdir /s /q $(cygpath -w "$GOS_INSTALL_DIR")" 2>/dev/null || rm -rf "$GOS_INSTALL_DIR"
    fi
  else
    sudo rm -rf "$GOS_INSTALL_DIR"
  fi
}

_gos_install_version() {
  local version=$1
  local os arch ext pkg url tmp_file

  os=$(_gos_os)
  arch=$(_gos_arch)
  ext=$(_gos_ext)

  if [ "$os" = "unsupported" ] || [ "$arch" = "unsupported" ]; then
    echo "❌ Unsupported OS or architecture: $os/$arch"
    return 1
  fi

  pkg="go${version}.${os}-${arch}.${ext}"
  url="https://go.dev/dl/${pkg}"
  tmp_file="/tmp/${pkg}"

  echo "⬇️  Downloading ${pkg}..."
  curl -L -o "$tmp_file" "$url" || {
    echo "❌ Download failed. Version '${version}' may not exist."
    rm -f "$tmp_file"
    return 1
  }

  echo "🗑️  Removing old Go installation..."
  _gos_remove_old

  echo "📦 Extracting..."
  if [ "$ext" = "zip" ]; then
    local install_parent
    install_parent=$(dirname "$GOS_INSTALL_DIR")
    unzip -q "$tmp_file" -d "$install_parent"
  else
    sudo tar -C "$(dirname "$GOS_INSTALL_DIR")" -xzf "$tmp_file"
  fi

  rm -f "$tmp_file"
  echo "✅ Done! $(go version)"
}

# ─── Commands ─────────────────────────────────────────────────────────────────

cmd_latest() {
  echo "🔍 Fetching latest stable Go version..."
  local latest current

  latest=$(_gos_fetch_latest)
  if [ -z "$latest" ]; then
    echo "❌ Could not fetch latest version. Check your internet connection."
    return 1
  fi

  current=$(_gos_current)
  echo "📌 Latest: go${latest}"

  if [ "$current" = "$latest" ]; then
    echo "✅ Already on Go ${latest}, nothing to do."
    return 0
  fi

  echo "🔄 Current: go${current} → go${latest}"
  _gos_install_version "$latest"
}

cmd_install() {
  local version=$1
  if [ -z "$version" ]; then
    echo "Usage: gos install <version>  e.g. gos install 1.26.1"
    return 1
  fi

  # Strip leading 'go' prefix if provided e.g. go1.26.1 → 1.26.1
  version="${version#go}"

  local current
  current=$(_gos_current)
  if [ "$current" = "$version" ]; then
    echo "✅ Already on Go ${version}, nothing to do."
    return 0
  fi

  _gos_install_version "$version"
}

cmd_current() {
  local current
  current=$(_gos_current)
  if [ "$current" = "none" ]; then
    echo "⚠️  No Go installation found."
  else
    echo "go${current}"
  fi
}

cmd_list() {
  echo "🔍 Fetching available Go versions..."
  curl -s 'https://go.dev/dl/?mode=json&include=all' \
    | grep -o '"version": "go[0-9.]*"' \
    | grep -o 'go[0-9][0-9.]*' \
    | sort -t. -k1,1V -k2,2n -k3,3n \
    | uniq
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
      echo "❌ Unknown command: $cmd"
      cmd_help
      return 1
      ;;
  esac
}

main "$@"
