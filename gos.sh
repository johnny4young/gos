#!/usr/bin/env bash
set -euo pipefail

GOS_VERSION="1.4.2"
GOS_INSTALL_DIR="${GOS_INSTALL_DIR:-/usr/local/go}"
GOS_CACHE_DIR="${GOS_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/gos}"
GOS_OUTPUT_JSON=0

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

_gos_json_enabled() {
  [ "$GOS_OUTPUT_JSON" = "1" ]
}

_gos_json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

_gos_json_string() {
  printf '"%s"' "$(_gos_json_escape "$1")"
}

_gos_set_json_from_args() {
  local arg
  for arg in "$@"; do
    if [ "$arg" = "--json" ]; then
      GOS_OUTPUT_JSON=1
    fi
  done
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
# Security: HTTPS integrity relies on the system CA certificate store.
# For hardened environments, set SSL_CERT_FILE or --cacert as needed.
# --proto '=https' / --https-only disallow any HTTP fallback even via redirect.
_gos_download() {
  local url="$1" output="$2"
  if command -v curl &>/dev/null; then
    curl --proto '=https' --tlsv1.2 -fsSL -o "$output" "$url"
  elif command -v wget &>/dev/null; then
    wget --https-only -qO "$output" "$url"
  else
    echo "Error: neither curl nor wget found. Install one and try again."
    return 1
  fi
}

# Download a URL to stdout. Supports curl and wget.
_gos_download_stdout() {
  local url="$1"
  if command -v curl &>/dev/null; then
    curl --proto '=https' --tlsv1.2 -fsSL "$url"
  elif command -v wget &>/dev/null; then
    wget --https-only -qO- "$url"
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

_gos_cache_path() {
  local pkg="$1"
  printf '%s/%s' "$GOS_CACHE_DIR" "$pkg"
}

_gos_store_cache() {
  local pkg="$1" archive="$2" expected_sha="$3"
  local cache_file

  [ -n "$expected_sha" ] || return 0
  cache_file=$(_gos_cache_path "$pkg")

  if mkdir -p "$GOS_CACHE_DIR" 2>/dev/null && cp "$archive" "$cache_file" 2>/dev/null; then
    return 0
  fi

  echo "Warning: could not write Go archive cache at ${GOS_CACHE_DIR}." >&2
}

_gos_try_cache() {
  local pkg="$1" output="$2" expected_sha="$3"
  local cache_file actual_sha

  cache_file=$(_gos_cache_path "$pkg")
  [ -f "$cache_file" ] || return 1

  if [ -z "$expected_sha" ]; then
    echo "Warning: cached ${pkg} was not reused because checksum metadata is unavailable." >&2
    return 1
  fi

  actual_sha=$(_gos_sha256 "$cache_file")
  if [ -z "$actual_sha" ]; then
    echo "Warning: cached ${pkg} was not reused because no SHA256 tool output was available." >&2
    return 1
  fi

  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "Warning: cached ${pkg} checksum mismatch; downloading a fresh archive." >&2
    return 1
  fi

  if ! cp "$cache_file" "$output"; then
    echo "Warning: cached ${pkg} could not be copied; downloading a fresh archive." >&2
    return 1
  fi
  echo "Using cached ${pkg}."
}

# Fetch expected SHA256 for a package filename from the Go API.
# Uses jq if available, falls back to python3 (always present on macOS).
_gos_has_checksum_parser() {
  command -v jq &>/dev/null || command -v python3 &>/dev/null
}

_gos_require_checksum() {
  [ "${GOS_REQUIRE_CHECKSUM:-}" = "1" ]
}

_gos_checksum_unavailable() {
  local reason="$1"

  if _gos_require_checksum; then
    echo "Error: checksum verification required but ${reason}." >&2
    return 1
  fi

  echo "Warning: skipping integrity verification (${reason})." >&2
}

_gos_fetch_checksum() {
  local pkg="$1"
  local include_all="${2:-false}"
  local json
  local api_url='https://go.dev/dl/?mode=json'

  if [ "$include_all" = "true" ]; then
    api_url='https://go.dev/dl/?mode=json&include=all'
  fi

  if ! _gos_has_checksum_parser; then
    echo ""
    return 0
  fi

  json=$(_gos_download_stdout "$api_url")

  if command -v jq &>/dev/null; then
    echo "$json" | jq -r --arg pkg "$pkg" '.[].files[] | select(.filename == $pkg) | .sha256'
  elif command -v python3 &>/dev/null; then
    echo "$json" | python3 -c "
import json, sys
pkg = sys.argv[1]
data = json.load(sys.stdin)
for v in data:
    for f in v.get('files', []):
        if f.get('filename') == pkg:
            print(f.get('sha256', ''))
            sys.exit(0)
" "$pkg"
  else
    echo ""
  fi
}

_gos_current() {
  if command -v go &>/dev/null; then
    go version | grep -Eo 'go[0-9]+\.[0-9]+(\.[0-9]+)?(rc[0-9]+|beta[0-9]+)?' | head -1 | sed 's/go//'
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

_gos_prepare_install_parent() {
  local parent
  parent=$(dirname "$GOS_INSTALL_DIR")

  if [ -d "$parent" ]; then
    return 0
  fi

  if mkdir -p "$parent" 2>/dev/null; then
    return 0
  fi

  if _gos_sudo mkdir -p "$parent"; then
    return 0
  fi

  echo "Error: failed to create parent directory for GOS_INSTALL_DIR: ${parent}" >&2
  return 1
}

_gos_extract_archive() {
  local ext="$1" tmp_file="$2" stage_dir="$3"
  local ps_archive ps_stage

  if [ "$ext" = "zip" ]; then
    if command -v unzip &>/dev/null; then
      unzip -q "$tmp_file" -d "$stage_dir"
    elif command -v tar &>/dev/null; then
      # Windows 10+ ships with tar that can handle zip.
      tar -xf "$tmp_file" -C "$stage_dir"
    elif command -v powershell.exe &>/dev/null && command -v cygpath &>/dev/null; then
      ps_archive=$(cygpath -w "$tmp_file") || {
        echo "Error: failed to convert archive path for PowerShell." >&2
        return 1
      }
      ps_stage=$(cygpath -w "$stage_dir") || {
        echo "Error: failed to convert stage path for PowerShell." >&2
        return 1
      }
      # The PowerShell command intentionally receives literal $env: lookups.
      # shellcheck disable=SC2016
      GOS_PS_ARCHIVE="$ps_archive" \
      GOS_PS_DESTINATION="$ps_stage" \
        powershell.exe -NoProfile -NonInteractive -Command \
          'Expand-Archive -LiteralPath $env:GOS_PS_ARCHIVE -DestinationPath $env:GOS_PS_DESTINATION -Force'
    else
      echo "Error: no extraction tool found (unzip, tar, or powershell with cygpath)." >&2
      return 1
    fi
  else
    tar -C "$stage_dir" -xzf "$tmp_file"
  fi
}

_gos_validate_staged_install() {
  local staged_go_dir="$1"
  local staged_go_bin="${staged_go_dir}/bin/go"

  if [ ! -x "$staged_go_bin" ]; then
    echo "Error: archive did not contain an executable go/bin/go." >&2
    return 1
  fi
}

_gos_restore_backup() {
  local backup_dir="$1"

  echo "Rolling back Go installation..."
  _gos_sudo rm -rf "$GOS_INSTALL_DIR" || return 1

  if [ -n "$backup_dir" ] && [ -d "$backup_dir" ]; then
    _gos_sudo mv "$backup_dir" "$GOS_INSTALL_DIR" || return 1
  fi
}

_gos_rollback_dir() {
  printf '%s.gos-rollback' "$GOS_INSTALL_DIR"
}

_gos_activate_staged_install() {
  local staged_go_dir="$1"
  local backup_dir=""
  local version_output

  if [ -e "$GOS_INSTALL_DIR" ]; then
    backup_dir="${GOS_INSTALL_DIR}.gos-backup.$$"
    if [ -e "$backup_dir" ]; then
      echo "Error: backup path already exists: ${backup_dir}" >&2
      return 1
    fi

    echo "Backing up existing Go installation..."
    _gos_sudo mv "$GOS_INSTALL_DIR" "$backup_dir" || return 1
  fi

  echo "Activating new Go installation..."
  if ! _gos_sudo mv "$staged_go_dir" "$GOS_INSTALL_DIR"; then
    echo "Error: failed to move new Go installation into place." >&2
    _gos_restore_backup "$backup_dir" || true
    return 1
  fi

  local go_bin="${GOS_INSTALL_DIR}/bin/go"
  if [ ! -x "$go_bin" ]; then
    echo "Error: activated Go installation is missing bin/go." >&2
    _gos_restore_backup "$backup_dir" || true
    return 1
  fi

  if ! version_output=$("$go_bin" version 2>&1); then
    echo "Error: activated Go failed validation: ${version_output}" >&2
    _gos_restore_backup "$backup_dir" || true
    return 1
  fi

  if [ -n "$backup_dir" ]; then
    local rollback_dir
    rollback_dir=$(_gos_rollback_dir)
    _gos_sudo rm -rf "$rollback_dir"
    _gos_sudo mv "$backup_dir" "$rollback_dir"
    echo "Rollback available: gos rollback"
  fi

  echo "Done! ${version_output}"
}

_gos_activate_rollback() {
  local rollback_dir current_backup version_output go_bin

  rollback_dir=$(_gos_rollback_dir)
  current_backup="${GOS_INSTALL_DIR}.gos-current.$$"

  if [ ! -d "$rollback_dir" ]; then
    echo "Error: no rollback installation found at ${rollback_dir}." >&2
    return 1
  fi

  if [ -e "$GOS_INSTALL_DIR" ]; then
    _gos_sudo mv "$GOS_INSTALL_DIR" "$current_backup" || return 1
  fi

  if ! _gos_sudo mv "$rollback_dir" "$GOS_INSTALL_DIR"; then
    echo "Error: failed to restore rollback installation." >&2
    if [ -e "$current_backup" ]; then
      _gos_sudo mv "$current_backup" "$GOS_INSTALL_DIR" || true
    fi
    return 1
  fi

  go_bin="${GOS_INSTALL_DIR}/bin/go"
  if [ ! -x "$go_bin" ]; then
    echo "Error: rollback installation is missing bin/go." >&2
    _gos_restore_backup "$current_backup" || true
    return 1
  fi

  if ! version_output=$("$go_bin" version 2>&1); then
    echo "Error: rollback Go failed validation: ${version_output}" >&2
    _gos_restore_backup "$current_backup" || true
    return 1
  fi

  if [ -e "$current_backup" ]; then
    _gos_sudo rm -rf "$rollback_dir"
    _gos_sudo mv "$current_backup" "$rollback_dir"
  fi

  echo "Rolled back! ${version_output}"
}

_gos_install_version() {
  local version=$1
  local include_all_checksums="${2:-false}"
  local os arch ext pkg url tmp_dir tmp_file stage_dir staged_go_dir

  _gos_validate_version "$version" || return 1

  os=$(_gos_os)
  arch=$(_gos_arch)
  ext=$(_gos_ext)

  if [ "$os" = "unsupported" ] || [ "$arch" = "unsupported" ]; then
    echo "Error: unsupported OS or architecture: detected $(uname -s)/$(uname -m) (mapped to ${os}/${arch})."
    return 1
  fi

  pkg="go${version}.${os}-${arch}.${ext}"
  url="https://go.dev/dl/${pkg}"

  # Use a unique temp directory to prevent symlink/TOCTOU attacks.
  tmp_dir=$(mktemp -d) || { echo "Error: failed to create temp directory." >&2; return 1; }
  tmp_file="${tmp_dir}/${pkg}"
  stage_dir="${tmp_dir}/stage"
  staged_go_dir="${stage_dir}/go"

  # Resolve checksum metadata before consulting the local archive cache.
  local expected_sha actual_sha cache_hit
  expected_sha=$(_gos_fetch_checksum "$pkg" "$include_all_checksums")
  cache_hit="false"

  if _gos_try_cache "$pkg" "$tmp_file" "$expected_sha"; then
    cache_hit="true"
  else
    echo "Downloading ${pkg}..."
    _gos_download "$url" "$tmp_file" || {
      echo "Error: download failed. Version '${version}' may not exist."
      rm -rf "$tmp_dir"
      return 1
    }
  fi

  # Verify checksum if tools are available.
  if [ -n "$expected_sha" ]; then
    actual_sha=$(_gos_sha256 "$tmp_file")
    if [ -z "$actual_sha" ]; then
      _gos_checksum_unavailable "no SHA256 tool output was available" || {
        rm -rf "$tmp_dir"
        return 1
      }
    elif [ "$actual_sha" != "$expected_sha" ]; then
      echo "Error: checksum mismatch! Expected ${expected_sha}, got ${actual_sha}."
      echo "The download may be corrupted. Aborting."
      rm -rf "$tmp_dir"
      return 1
    else
      echo "Checksum verified."
      if [ "$cache_hit" != "true" ]; then
        _gos_store_cache "$pkg" "$tmp_file" "$expected_sha"
      fi
    fi
  else
    local reason
    if _gos_has_checksum_parser; then
      reason="checksum metadata was not found for ${pkg}"
    else
      reason="jq or python3 is required to read checksum metadata"
    fi
    _gos_checksum_unavailable "$reason" || {
      rm -rf "$tmp_dir"
      return 1
    }
  fi

  echo "Extracting..."
  mkdir -p "$stage_dir"
  if ! _gos_extract_archive "$ext" "$tmp_file" "$stage_dir"; then
    echo "Error: extraction failed."
    rm -rf "$tmp_dir"
    return 1
  fi

  if ! _gos_validate_staged_install "$staged_go_dir"; then
    rm -rf "$tmp_dir"
    return 1
  fi

  if ! _gos_prepare_install_parent; then
    rm -rf "$tmp_dir"
    return 1
  fi

  if ! _gos_activate_staged_install "$staged_go_dir"; then
    rm -rf "$tmp_dir"
    return 1
  fi

  rm -rf "$tmp_dir"
}

_gos_find_upward() {
  local start_dir="$1" filename="$2" dir
  dir=$(cd "$start_dir" 2>/dev/null && pwd) || return 1

  while [ "$dir" != "/" ]; do
    if [ -f "${dir}/${filename}" ]; then
      printf '%s\n' "${dir}/${filename}"
      return 0
    fi
    dir=$(dirname "$dir")
  done

  return 1
}

_gos_read_go_version_file() {
  local file="$1" line
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$line" ] && continue
    line="${line#go}"
    printf '%s\n' "$line"
    return 0
  done < "$file"
  return 1
}

_gos_read_go_mod_version() {
  local file="$1"
  awk '
    $1 == "toolchain" && $2 ~ /^go[0-9]+\.[0-9]+/ {
      sub(/^go/, "", $2)
      toolchain = $2
    }
    $1 == "go" && $2 ~ /^[0-9]+\.[0-9]+/ && go_version == "" {
      go_version = $2
    }
    END {
      if (toolchain != "") {
        print toolchain
      } else if (go_version != "") {
        print go_version
      } else {
        exit 1
      }
    }
  ' "$file"
}

_gos_resolve_project_version() {
  local start_dir="$1" version_file go_mod version

  if version_file=$(_gos_find_upward "$start_dir" ".go-version"); then
    version=$(_gos_read_go_version_file "$version_file") || return 1
    printf '%s|%s\n' "$version" "$version_file"
    return 0
  fi

  if go_mod=$(_gos_find_upward "$start_dir" "go.mod"); then
    version=$(_gos_read_go_mod_version "$go_mod") || return 1
    printf '%s|%s\n' "$version" "$go_mod"
    return 0
  fi

  return 1
}

_gos_list_versions() {
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

_gos_platforms_for_version() {
  local version="$1" json go_version
  go_version="go${version#go}"
  json=$(_gos_download_stdout 'https://go.dev/dl/?mode=json&include=all')

  if command -v jq &>/dev/null; then
    echo "$json" \
      | jq -r --arg version "$go_version" \
        '.[] | select(.version == $version) | .files[] | select(.kind == "archive") | "\(.os)/\(.arch)"' \
      | sort -u
  elif command -v python3 &>/dev/null; then
    echo "$json" | python3 -c '
import json
import sys

version = sys.argv[1]
data = json.load(sys.stdin)
platforms = set()
for item in data:
    if item.get("version") != version:
        continue
    for file in item.get("files", []):
        if file.get("kind") == "archive":
            platforms.add(f"{file.get('os')}/{file.get('arch')}")
for platform in sorted(platforms):
    print(platform)
' "$go_version"
  else
    echo "$json" \
      | grep -o "${go_version}\\.[^\"]*" \
      | sed -E "s/^${go_version//./\\.}\\.([^-]+)-([^.]*)\\..*/\\1\\/\\2/" \
      | sort -u
  fi
}

_gos_json_array_from_lines() {
  local first="true" line
  printf '['
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [ "$first" = "true" ]; then
      first="false"
    else
      printf ','
    fi
    _gos_json_string "$line"
  done
  printf ']'
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

  _gos_install_version "$version" true
}

cmd_current() {
  local current
  _gos_set_json_from_args "$@"
  current=$(_gos_current)
  if _gos_json_enabled; then
    if [ "$current" = "none" ]; then
      printf '{"found":false,"version":null,"current":null}\n'
    else
      printf '{"found":true,"version":'
      _gos_json_string "$current"
      printf ',"current":'
      _gos_json_string "go${current}"
      printf '}\n'
    fi
    return 0
  fi

  if [ "$current" = "none" ]; then
    echo "No Go installation found."
  else
    echo "go${current}"
  fi
}

cmd_list() {
  _gos_set_json_from_args "$@"
  if _gos_json_enabled; then
    printf '{"versions":'
    _gos_list_versions | _gos_json_array_from_lines
    printf '}\n'
  else
    echo "Fetching available Go versions..."
    _gos_list_versions
  fi
}

cmd_platforms() {
  local version="" arg platforms
  for arg in "$@"; do
    if [ "$arg" = "--json" ]; then
      GOS_OUTPUT_JSON=1
    elif [ -z "$version" ]; then
      version="${arg#go}"
    fi
  done

  if [ -z "$version" ]; then
    version=$(_gos_fetch_latest)
  fi

  _gos_validate_version "$version" || return 1
  platforms=$(_gos_platforms_for_version "$version")

  if [ -z "$platforms" ]; then
    echo "Error: no supported platforms found for go${version}." >&2
    return 1
  fi

  if _gos_json_enabled; then
    printf '{"version":'
    _gos_json_string "go${version}"
    printf ',"platforms":'
    printf '%s\n' "$platforms" | _gos_json_array_from_lines
    printf '}\n'
    return 0
  fi

  echo "Supported platforms for go${version}:"
  printf '%s\n' "$platforms"
}

cmd_use() {
  local start_dir="${1:-$PWD}" resolved version source

  if [ "$start_dir" = "--json" ]; then
    echo "Error: gos use does not support --json." >&2
    return 1
  fi

  if ! resolved=$(_gos_resolve_project_version "$start_dir"); then
    echo "Error: no .go-version or go.mod found from ${start_dir} upward." >&2
    return 1
  fi

  version="${resolved%%|*}"
  source="${resolved#*|}"
  version="${version#go}"

  _gos_validate_version "$version" || return 1
  echo "Using Go ${version} from ${source}"
  cmd_install "$version"
}

cmd_pin() {
  local version="${1:-}"
  if [ -z "$version" ]; then
    echo "Usage: gos pin <version>  e.g. gos pin 1.24.0" >&2
    return 1
  fi

  version="${version#go}"
  _gos_validate_version "$version" || return 1
  printf '%s\n' "$version" > .go-version
  echo "Pinned Go ${version} in .go-version"
}

cmd_rollback() {
  _gos_activate_rollback
}

_gos_doctor_add_json_check() {
  local status="$1" name="$2" message="$3" fix="$4"

  if [ -n "${GOS_DOCTOR_JSON_ITEMS:-}" ]; then
    GOS_DOCTOR_JSON_ITEMS="${GOS_DOCTOR_JSON_ITEMS},"
  fi

  GOS_DOCTOR_JSON_ITEMS="${GOS_DOCTOR_JSON_ITEMS}{\"name\":$(_gos_json_string "$name"),\"status\":$(_gos_json_string "$status"),\"message\":$(_gos_json_string "$message")"
  if [ -n "$fix" ]; then
    GOS_DOCTOR_JSON_ITEMS="${GOS_DOCTOR_JSON_ITEMS},\"fix\":$(_gos_json_string "$fix")"
  fi
  GOS_DOCTOR_JSON_ITEMS="${GOS_DOCTOR_JSON_ITEMS}}"
}

_gos_doctor_check() {
  local status="$1" name="$2" message="$3" fix="${4:-}"

  [ "$status" = "problem" ] && GOS_DOCTOR_PROBLEMS=$((GOS_DOCTOR_PROBLEMS + 1))
  [ "$status" = "warn" ] && GOS_DOCTOR_WARNINGS=$((GOS_DOCTOR_WARNINGS + 1))

  if _gos_json_enabled; then
    _gos_doctor_add_json_check "$status" "$name" "$message" "$fix"
    return 0
  fi

  printf '%s - %s: %s\n' "$status" "$name" "$message"
  if [ -n "$fix" ]; then
    printf 'fix - %s\n' "$fix"
  fi
}

_gos_parent_writable_or_sudo() {
  local dir="$1" parent
  parent=$(dirname "$dir")

  while [ ! -d "$parent" ] && [ "$parent" != "/" ]; do
    parent=$(dirname "$parent")
  done

  [ -w "$parent" ] && return 0
  [ "$(_gos_os)" != "windows" ] && command -v sudo &>/dev/null && return 0
  return 1
}

cmd_doctor() {
  local os arch raw_os raw_arch install_error go_path go_version go_bin
  GOS_DOCTOR_PROBLEMS=0
  GOS_DOCTOR_WARNINGS=0
  GOS_DOCTOR_JSON_ITEMS=""
  _gos_set_json_from_args "$@"

  os=$(_gos_os)
  arch=$(_gos_arch)
  raw_os=$(uname -s)
  raw_arch=$(uname -m)
  if [ "$os" = "unsupported" ] || [ "$arch" = "unsupported" ]; then
    _gos_doctor_check "problem" "platform" "unsupported platform detected: ${raw_os}/${raw_arch}" "Open an issue with the detected OS and architecture before installing Go."
  else
    _gos_doctor_check "ok" "platform" "detected ${os}/${arch} from ${raw_os}/${raw_arch}"
  fi

  if install_error=$(_gos_validate_install_dir "$GOS_INSTALL_DIR" 2>&1); then
    if [ -d "$GOS_INSTALL_DIR" ] && [ -w "$GOS_INSTALL_DIR" ]; then
      _gos_doctor_check "ok" "install-dir" "${GOS_INSTALL_DIR} exists and is writable"
    elif _gos_parent_writable_or_sudo "$GOS_INSTALL_DIR"; then
      _gos_doctor_check "ok" "install-dir" "${GOS_INSTALL_DIR} can be created or updated"
    else
      _gos_doctor_check "problem" "install-dir" "${GOS_INSTALL_DIR} is not writable and sudo is unavailable" "Use GOS_INSTALL_DIR under your home directory or install sudo."
    fi
  else
    _gos_doctor_check "problem" "install-dir" "$install_error" "Set GOS_INSTALL_DIR to a safe path whose basename contains go."
  fi

  if go_path=$(command -v go 2>/dev/null); then
    go_version=$(go version 2>/dev/null || true)
    _gos_doctor_check "ok" "go" "${go_path} reports: ${go_version}"
  else
    _gos_doctor_check "problem" "go" "go is not on PATH" "Run gos latest or add ${GOS_INSTALL_DIR}/bin to PATH after installing Go."
  fi

  go_bin="${GOS_INSTALL_DIR}/bin"
  if [ -d "$go_bin" ] && go_path=$(command -v go 2>/dev/null); then
    case "$go_path" in
      "${go_bin}/go"|*"\\${go_bin}\\go.exe")
        _gos_doctor_check "ok" "path-order" "PATH resolves go from ${go_bin}"
        ;;
      *)
        _gos_doctor_check "problem" "path-order" "PATH resolves go from ${go_path}, not ${go_bin}" "Put ${go_bin} before other Go installations in PATH."
        ;;
    esac
  elif [ -d "$go_bin" ]; then
    _gos_doctor_check "problem" "path-order" "${go_bin} exists but go is not on PATH" "Add ${go_bin} to PATH."
  else
    _gos_doctor_check "warn" "path-order" "${go_bin} does not exist yet"
  fi

  if command -v curl &>/dev/null || command -v wget &>/dev/null; then
    _gos_doctor_check "ok" "download" "curl or wget is available"
  else
    _gos_doctor_check "problem" "download" "neither curl nor wget is available" "Install curl or wget."
  fi

  if _gos_has_checksum_parser; then
    _gos_doctor_check "ok" "checksum-metadata" "jq or python3 is available"
  elif _gos_require_checksum; then
    _gos_doctor_check "problem" "checksum-metadata" "GOS_REQUIRE_CHECKSUM=1 but jq/python3 is missing" "Install jq or python3."
  else
    _gos_doctor_check "warn" "checksum-metadata" "jq/python3 is missing; checksum metadata cannot be parsed"
  fi

  if [ -n "$(_gos_sha256 "$0")" ]; then
    _gos_doctor_check "ok" "checksum-hash" "SHA256 hash tool is available"
  elif _gos_require_checksum; then
    _gos_doctor_check "problem" "checksum-hash" "GOS_REQUIRE_CHECKSUM=1 but no SHA256 tool is available" "Install sha256sum or shasum."
  else
    _gos_doctor_check "warn" "checksum-hash" "no SHA256 tool found; downloads cannot be locally hashed"
  fi

  if [ "$os" = "windows" ]; then
    if command -v unzip &>/dev/null || command -v tar &>/dev/null || { command -v powershell.exe &>/dev/null && command -v cygpath &>/dev/null; }; then
      _gos_doctor_check "ok" "extract" "Windows zip extraction tool is available"
    else
      _gos_doctor_check "problem" "extract" "no Windows extraction tool is available" "Install unzip, tar, or Git for Windows with PowerShell access."
    fi
  elif command -v tar &>/dev/null; then
    _gos_doctor_check "ok" "extract" "tar is available"
  else
    _gos_doctor_check "problem" "extract" "tar is not available" "Install tar."
  fi

  if [ -f "${BASH_SOURCE[0]%/*}/completions/gos.bash" ] && [ -f "${BASH_SOURCE[0]%/*}/completions/gos.zsh" ] && [ -f "${BASH_SOURCE[0]%/*}/completions/gos.fish" ]; then
    _gos_doctor_check "ok" "completions" "Bash, Zsh, and Fish completion files are present"
  else
    _gos_doctor_check "warn" "completions" "one or more completion files are missing"
  fi

  if _gos_json_enabled; then
    if [ "$GOS_DOCTOR_PROBLEMS" -gt 0 ]; then
      printf '{"status":"problem","problems":%s,"warnings":%s,"checks":[%s]}\n' "$GOS_DOCTOR_PROBLEMS" "$GOS_DOCTOR_WARNINGS" "$GOS_DOCTOR_JSON_ITEMS"
    else
      printf '{"status":"ok","problems":0,"warnings":%s,"checks":[%s]}\n' "$GOS_DOCTOR_WARNINGS" "$GOS_DOCTOR_JSON_ITEMS"
    fi
  fi

  [ "$GOS_DOCTOR_PROBLEMS" -eq 0 ]
}

cmd_version() {
  _gos_set_json_from_args "$@"
  if _gos_json_enabled; then
    printf '{"gos_version":'
    _gos_json_string "$GOS_VERSION"
    printf '}\n'
    return 0
  fi

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
  use [path]          Install the Go version requested by .go-version or go.mod
  pin <version>       Write .go-version in the current directory
  rollback            Restore the previous Go installation, if available
  current             Show the currently active Go version
  list                List all available Go versions
  platforms [version] List supported OS/arch archives for a Go version
  doctor              Diagnose gos, Go, PATH, and tool dependencies
  version             Show gos version
  help                Show this help message

OPTIONS:
  --json              Machine-readable output for current, list, platforms,
                      doctor, and version

EXAMPLES:
  gos latest
  gos install 1.24.0
  gos use
  gos pin 1.24.0
  gos doctor
  gos current
  gos list --json

EOF
}

# ─── Entrypoint ───────────────────────────────────────────────────────────────

main() {
  if [ "${1:-}" = "--json" ]; then
    GOS_OUTPUT_JSON=1
    shift
  fi

  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    latest)
      _gos_validate_install_dir "$GOS_INSTALL_DIR" || return 1
      cmd_latest "$@"
      ;;
    install)
      _gos_validate_install_dir "$GOS_INSTALL_DIR" || return 1
      cmd_install "${1:-}"
      ;;
    use)
      _gos_validate_install_dir "$GOS_INSTALL_DIR" || return 1
      cmd_use "${1:-}"
      ;;
    pin)       cmd_pin "${1:-}" ;;
    rollback)
      _gos_validate_install_dir "$GOS_INSTALL_DIR" || return 1
      cmd_rollback
      ;;
    current)   cmd_current "$@" ;;
    list)      cmd_list "$@" ;;
    platforms) cmd_platforms "$@" ;;
    doctor)    cmd_doctor "$@" ;;
    version)   cmd_version "$@" ;;
    help|--help|-h) cmd_help ;;
    *)
      echo "Error: unknown command: $cmd"
      cmd_help
      return 1
      ;;
  esac
}

main "$@"
