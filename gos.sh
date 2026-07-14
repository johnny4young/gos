#!/usr/bin/env bash
set -euo pipefail

GOS_VERSION="1.6.0"
GOS_INSTALL_DIR="${GOS_INSTALL_DIR:-/usr/local/go}"
# Strip trailing slashes so sibling paths (backup, rollback) are computed as
# true siblings: /usr/local/go/ would otherwise yield /usr/local/go/.gos-backup.
while [ "$GOS_INSTALL_DIR" != "/" ] && [ "$GOS_INSTALL_DIR" != "${GOS_INSTALL_DIR%/}" ]; do
  GOS_INSTALL_DIR="${GOS_INSTALL_DIR%/}"
done
GOS_CACHE_DIR="${GOS_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/gos}"
# Optional HTTPS mirror for Go archive downloads (e.g. https://golang.google.cn/dl).
# Version/checksum metadata always comes from go.dev, so mirror bytes are still
# verified against the official checksums before activation.
GOS_DOWNLOAD_MIRROR="${GOS_DOWNLOAD_MIRROR:-}"
# Discovery-only Go downloads feed cache TTL in seconds. Set to 0 to disable
# the on-disk feed cache and force discovery commands to fetch every run.
GOS_FEED_TTL="${GOS_FEED_TTL:-600}"
# Opt-in side-by-side layout: when set, each Go version is installed under
# $GOS_VERSIONS_DIR/go<version> and GOS_INSTALL_DIR becomes a symlink to the
# active one, making version switches instant and enabling gos uninstall.
GOS_VERSIONS_DIR="${GOS_VERSIONS_DIR:-}"
while [ -n "$GOS_VERSIONS_DIR" ] && [ "$GOS_VERSIONS_DIR" != "/" ] && [ "$GOS_VERSIONS_DIR" != "${GOS_VERSIONS_DIR%/}" ]; do
  GOS_VERSIONS_DIR="${GOS_VERSIONS_DIR%/}"
done
GOS_RELEASE_BASE_URL="https://github.com/johnny4young/gos/releases/latest/download"
GOS_OUTPUT_JSON=0
GOS_TMP_DIR=""
GOS_LOCK_DIR=""

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Set while the previous installation sits in a backup dir during activation.
# The EXIT trap restores it if gos dies between the backup mv and the
# activation mv, so an interrupt cannot leave the machine with no Go at all.
GOS_ACTIVATION_BACKUP=""

# Temp staging is cleaned from a trap so interrupted installs (Ctrl-C, kill)
# do not leak partially extracted archives.
_gos_cleanup_tmp() {
  # Restore the backup only if the install slot is genuinely empty. -L catches a
  # side-by-side symlink backup (for which -d would be false) and guards against
  # clobbering a symlink that the activation step already managed to create.
  if [ -n "$GOS_ACTIVATION_BACKUP" ] \
     && { [ -e "$GOS_ACTIVATION_BACKUP" ] || [ -L "$GOS_ACTIVATION_BACKUP" ]; } \
     && [ ! -e "$GOS_INSTALL_DIR" ] && [ ! -L "$GOS_INSTALL_DIR" ]; then
    echo "Interrupted during activation; restoring the previous Go installation..." >&2
    # The backup was created with sudo for root-owned installs (default
    # /usr/local/go), so a plain mv cannot restore it; escalate on failure or the
    # trap would leave the machine with no Go at all.
    if ! mv "$GOS_ACTIVATION_BACKUP" "$GOS_INSTALL_DIR" 2>/dev/null; then
      if [ "$(_gos_os)" != "windows" ] && command -v sudo &>/dev/null \
         && sudo mv "$GOS_ACTIVATION_BACKUP" "$GOS_INSTALL_DIR" 2>/dev/null; then
        :
      else
        echo "Warning: could not restore ${GOS_ACTIVATION_BACKUP}; move it back to ${GOS_INSTALL_DIR} manually." >&2
      fi
    fi
  fi
  if [ -n "$GOS_TMP_DIR" ] && [ -d "$GOS_TMP_DIR" ]; then
    rm -rf "$GOS_TMP_DIR"
  fi
  if [ -n "$GOS_LOCK_DIR" ] && [ -d "$GOS_LOCK_DIR" ]; then
    _gos_sudo rm -rf "$GOS_LOCK_DIR" 2>/dev/null || rm -rf "$GOS_LOCK_DIR" 2>/dev/null || true
    GOS_LOCK_DIR=""
  fi
}
trap _gos_cleanup_tmp EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
    # Go ships a single 32-bit ARM build (armv6l); armv7l/armv8l CPUs run it.
    armv6l|armv7l|armv8l) echo "armv6l" ;;
    i386|i486|i586|i686) echo "386" ;;
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

# Parse the flags shared by commands that take only [--json]. Unknown arguments
# are rejected rather than silently ignored, so `gos check --bogus` errors like
# the hand-rolled parsers in list/env/prune already do.
_gos_set_json_from_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --json) GOS_OUTPUT_JSON=1 ;;
      *)
        echo "Error: unexpected argument: ${arg}" >&2
        return 1
        ;;
    esac
  done
}

# Validate version string to prevent path traversal and URL injection.
# Accepts: 1.22, 1.22.0, 1.23rc1, 1.23beta2
_gos_validate_version() {
  local version="$1"
  if ! printf '%s\n' "$version" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?(rc[0-9]+|beta[0-9]+)?$'; then
    echo "Error: invalid version format '${version}'." >&2
    echo "Expected format: X.Y[.Z][rcN|betaN]  e.g. 1.22.0, 1.23rc1" >&2
    return 1
  fi
}

# Reject path values that are unsafe to interpolate or to feed to privileged
# rm -rf/mv. Shared by every user-controlled directory knob so a hardening added
# here (e.g. the shell-metacharacter denylist) can never drift between them.
# Usage: _gos_reject_unsafe_path <var-name> <value>
_gos_reject_unsafe_path() {
  local label="$1" value="$2"
  # Reject control characters that make paths ambiguous in logs and commands.
  case "$value" in
    *$'\n'*|*$'\r'*|*$'\t'*)
      echo "Error: ${label} must not contain control characters." >&2
      return 1
      ;;
  esac
  # Reject . and .. components; without canonicalization they would let a path
  # like /usr/local/../../etc/go slip past the system-critical denylist.
  case "/${value}/" in
    *"/../"*|*"/./"*)
      echo "Error: ${label}='${value}' must not contain . or .. path components." >&2
      return 1
      ;;
  esac
}

# Guard against catastrophic rm -rf on dangerous paths.
_gos_validate_install_dir() {
  local dir="$1"
  # Reject empty
  if [ -z "$dir" ]; then
    echo "Error: GOS_INSTALL_DIR is empty." >&2
    return 1
  fi
  # Require an absolute path so install/cleanup never depends on the CWD
  case "$dir" in
    /*) ;;
    *)
      echo "Error: GOS_INSTALL_DIR='${dir}' must be an absolute path." >&2
      return 1
      ;;
  esac
  _gos_reject_unsafe_path "GOS_INSTALL_DIR" "$dir" || return 1
  # Reject known system-critical roots
  case "$dir" in
    /|/usr|/etc|/home|/var|/bin|/sbin|/lib|/opt|/tmp|/root|/sys|/proc|/dev)
      echo "Error: GOS_INSTALL_DIR='${dir}' is a system-critical path. Refusing." >&2
      return 1
      ;;
  esac
  # Require at least 2 path components (e.g. /usr/local/go, not /go)
  local depth
  depth=$(printf '%s' "$dir" | tr -cd '/' | wc -c | tr -d ' ')
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

# Validate the optional side-by-side versions directory.
_gos_validate_versions_dir() {
  [ -z "$GOS_VERSIONS_DIR" ] && return 0
  # Git Bash's ln -s copies instead of linking, which would silently turn
  # "instant switching" into full copies with broken uninstall semantics.
  if [ "$(_gos_os)" = "windows" ]; then
    echo "Error: GOS_VERSIONS_DIR (side-by-side mode) requires real symlinks and is not supported on Git Bash. Use WSL, or unset GOS_VERSIONS_DIR." >&2
    return 1
  fi
  case "$GOS_VERSIONS_DIR" in
    /*) ;;
    *)
      echo "Error: GOS_VERSIONS_DIR='${GOS_VERSIONS_DIR}' must be an absolute path." >&2
      return 1
      ;;
  esac
  _gos_reject_unsafe_path "GOS_VERSIONS_DIR" "$GOS_VERSIONS_DIR" || return 1
}

_gos_versions_mode() {
  [ -n "$GOS_VERSIONS_DIR" ]
}

# Warn when a mutating command would silently convert a side-by-side layout back
# to a flat install because GOS_VERSIONS_DIR is unset in this shell (e.g. a cron
# job or sudo shell that doesn't source the user's rc). Fires only when the
# install dir is a symlink into a gos-managed go<version> directory, so an
# unrelated manual symlink does not trigger it.
_gos_warn_orphaned_versions_link() {
  _gos_versions_mode && return 0
  [ -L "$GOS_INSTALL_DIR" ] || return 0
  local target base
  target=$(readlink "$GOS_INSTALL_DIR") || return 0
  base="${target##*/}"
  case "$base" in
    go[0-9]*)
      if _gos_validate_version "${base#go}" 2>/dev/null; then
        echo "Warning: ${GOS_INSTALL_DIR} is a side-by-side symlink (-> ${target}) but GOS_VERSIONS_DIR is not set in this shell." >&2
        echo "         Proceeding will convert it to a flat install; export GOS_VERSIONS_DIR to keep managing versions side by side." >&2
      fi
      ;;
  esac
  return 0
}

_gos_version_dir_for() {
  printf '%s/go%s' "$GOS_VERSIONS_DIR" "$1"
}

# Validate the optional archive download mirror. HTTPS is required because the
# download helpers refuse plaintext HTTP, and a malformed value should fail
# fast instead of producing confusing 404s.
_gos_validate_mirror() {
  [ -z "$GOS_DOWNLOAD_MIRROR" ] && return 0
  case "$GOS_DOWNLOAD_MIRROR" in
    https://*[!/]*) ;;
    *)
      echo "Error: GOS_DOWNLOAD_MIRROR='${GOS_DOWNLOAD_MIRROR}' must be an https:// URL." >&2
      return 1
      ;;
  esac
}

# Base URL that Go archives are downloaded from. The mirror only replaces the
# archive source; the version feed and checksum metadata still come from go.dev.
_gos_archive_base_url() {
  if [ -n "$GOS_DOWNLOAD_MIRROR" ]; then
    printf '%s' "${GOS_DOWNLOAD_MIRROR%/}"
  else
    printf '%s' "https://go.dev/dl"
  fi
}

# Download a URL to a file. Supports curl and wget.
# Security: HTTPS integrity relies on the system CA certificate store.
# For hardened environments, set SSL_CERT_FILE or --cacert as needed.
# --proto '=https' / --https-only disallow any HTTP fallback even via redirect.
_gos_download() {
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

# Download a URL to stdout. Supports curl and wget.
_gos_download_stdout() {
  local url="$1"
  if command -v curl &>/dev/null; then
    curl --proto '=https' --tlsv1.2 --connect-timeout 15 --retry 2 -fsSL "$url"
  elif command -v wget &>/dev/null; then
    wget --https-only --timeout=15 --tries=3 -qO- "$url"
  else
    echo "Error: neither curl nor wget found. Install one and try again." >&2
    return 1
  fi
}

# ─── Go downloads feed ────────────────────────────────────────────────────────
# The feed is fetched at most once per feed variant per run. Helpers that run
# inside command substitutions inherit a cache warmed in the parent shell, so
# commands like `gos latest` resolve version and checksum with one request.

GOS_FEED_JSON_DEFAULT=""
GOS_FEED_JSON_ALL=""

_gos_feed_cache_enabled() {
  case "$GOS_FEED_TTL" in
    ''|*[!0-9]*|0) return 1 ;;
    *) return 0 ;;
  esac
}

_gos_feed_cache_path() {
  local include_all="$1"
  if [ "$include_all" = "true" ]; then
    printf '%s/feed-all.json' "$GOS_CACHE_DIR"
  else
    printf '%s/feed-default.json' "$GOS_CACHE_DIR"
  fi
}

_gos_file_mtime() {
  local file="$1"
  stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null
}

_gos_feed_cache_fresh() {
  local cache_file="$1" mtime now age

  _gos_feed_cache_enabled || return 1
  [ -f "$cache_file" ] || return 1
  mtime=$(_gos_file_mtime "$cache_file") || return 1
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s 2>/dev/null) || return 1
  age=$((now - mtime))
  [ "$age" -ge 0 ] && [ "$age" -le "$GOS_FEED_TTL" ]
}

_gos_cached_feed_json() {
  local include_all="$1" cache_file
  cache_file=$(_gos_feed_cache_path "$include_all")
  _gos_feed_cache_fresh "$cache_file" || return 1
  cat "$cache_file"
}

_gos_write_feed_cache() {
  local include_all="$1" json="$2" cache_file tmp_file

  _gos_feed_cache_enabled || return 0
  cache_file=$(_gos_feed_cache_path "$include_all")
  if ! mkdir -p "$GOS_CACHE_DIR" 2>/dev/null; then
    echo "Warning: could not write Go downloads feed cache at ${GOS_CACHE_DIR}." >&2
    return 0
  fi
  tmp_file=$(mktemp "${cache_file}.XXXXXX" 2>/dev/null) || {
    echo "Warning: could not write Go downloads feed cache at ${GOS_CACHE_DIR}." >&2
    return 0
  }
  printf '%s\n' "$json" >"$tmp_file" || {
    rm -f "$tmp_file"
    echo "Warning: could not write Go downloads feed cache at ${GOS_CACHE_DIR}." >&2
    return 0
  }
  mv "$tmp_file" "$cache_file" 2>/dev/null || {
    rm -f "$tmp_file"
    echo "Warning: could not write Go downloads feed cache at ${GOS_CACHE_DIR}." >&2
    return 0
  }
}

_gos_feed_json() {
  local include_all="${1:-false}"
  local allow_disk_cache="${2:-false}" json

  if [ "$include_all" = "true" ]; then
    if [ -z "$GOS_FEED_JSON_ALL" ]; then
      if [ "$allow_disk_cache" = "true" ] && json=$(_gos_cached_feed_json true); then
        GOS_FEED_JSON_ALL="$json"
      else
        GOS_FEED_JSON_ALL=$(_gos_download_stdout 'https://go.dev/dl/?mode=json&include=all') || return 1
        [ "$allow_disk_cache" = "true" ] && _gos_write_feed_cache true "$GOS_FEED_JSON_ALL"
      fi
    fi
    printf '%s\n' "$GOS_FEED_JSON_ALL"
  else
    if [ -z "$GOS_FEED_JSON_DEFAULT" ]; then
      if [ "$allow_disk_cache" = "true" ] && json=$(_gos_cached_feed_json false); then
        GOS_FEED_JSON_DEFAULT="$json"
      else
        GOS_FEED_JSON_DEFAULT=$(_gos_download_stdout 'https://go.dev/dl/?mode=json') || return 1
        [ "$allow_disk_cache" = "true" ] && _gos_write_feed_cache false "$GOS_FEED_JSON_DEFAULT"
      fi
    fi
    printf '%s\n' "$GOS_FEED_JSON_DEFAULT"
  fi
}

# Print bare version numbers (no "go" prefix) from feed JSON in feed order,
# using the most robust parser available.
_gos_feed_versions() {
  local json="$1"

  if command -v jq &>/dev/null; then
    printf '%s\n' "$json" | jq -r '.[].version' | sed 's/^go//'
  elif command -v python3 &>/dev/null; then
    printf '%s\n' "$json" | python3 -c '
import json, sys

for item in json.load(sys.stdin):
    version = item.get("version", "")
    print(version[2:] if version.startswith("go") else version)
'
  else
    # Last-resort text scraping; the character class keeps rc/beta suffixes.
    printf '%s\n' "$json" \
      | grep -o '"version": *"go[0-9][0-9A-Za-z.]*"' \
      | grep -o 'go[0-9][0-9A-Za-z.]*' \
      | sed 's/^go//'
  fi
}

_gos_fetch_latest() {
  local allow_disk_cache="${1:-false}"
  local json
  json=$(_gos_feed_json false "$allow_disk_cache") || return 1
  _gos_feed_versions "$json" | head -1
}

# Resolve a bare X.Y version to the newest matching release in the feed.
# Since Go 1.21 the first release of every minor ships as X.Y.0, so `gos
# install 1.22` (or a go.mod `go 1.22` directive) has no matching archive.
# Older minors did ship a bare X.Y release, which the feed also lists, so the
# newest feed match (feed order is newest-first) is correct for both eras.
# Prints the input unchanged when it already has a patch or pre-release
# component, or when the feed is unavailable.
_gos_resolve_bare_minor() {
  local version="$1" json resolved escaped

  case "$version" in
    *rc*|*beta*|*.*.*) printf '%s\n' "$version"; return 0 ;;
  esac

  json=$(_gos_feed_json true) || { printf '%s\n' "$version"; return 0; }
  escaped=${version//./\\.}
  resolved=$(_gos_feed_versions "$json" | grep -E "^${escaped}(\.[0-9]+)?$" | head -1) || resolved=""

  if [ -n "$resolved" ]; then
    printf '%s\n' "$resolved"
  else
    printf '%s\n' "$version"
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

# GOS_REQUIRE_CHECKSUM=1    -> fail closed when no checksum can be verified.
# GOS_REQUIRE_CHECKSUM=feed -> additionally require the digest to come from
#   the go.dev downloads feed (cross-origin from the archive host), rejecting
#   the same-origin .sha256 companion-file fallback.
_gos_require_checksum() {
  [ "${GOS_REQUIRE_CHECKSUM:-}" = "1" ] || [ "${GOS_REQUIRE_CHECKSUM:-}" = "feed" ]
}

_gos_require_feed_checksum() {
  [ "${GOS_REQUIRE_CHECKSUM:-}" = "feed" ]
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

  if ! _gos_has_checksum_parser; then
    echo ""
    return 0
  fi

  json=$(_gos_feed_json "$include_all") || { echo ""; return 0; }

  if command -v jq &>/dev/null; then
    printf '%s\n' "$json" | jq -r --arg pkg "$pkg" '.[].files[] | select(.filename == $pkg) | .sha256'
  elif command -v python3 &>/dev/null; then
    printf '%s\n' "$json" | python3 -c "
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

# Fallback checksum source: the companion .sha256 file published next to each
# archive. go.dev redirects archive downloads to dl.google.com, so this stays
# within the trust boundary already used for the archive bytes. It enables
# verification even when jq/python3 are unavailable or feed metadata is absent.
_gos_fetch_checksum_file() {
  local pkg="$1" sha

  sha=$(_gos_download_stdout "https://dl.google.com/go/${pkg}.sha256" 2>/dev/null) || return 1
  # Some companion files publish "<sha256>  <filename>"; keep only the digest.
  sha="${sha%%[[:space:]]*}"
  case "$sha" in
    *[!0-9a-fA-F]*) return 1 ;;
  esac
  if [ "${#sha}" -ne 64 ]; then
    return 1
  fi

  printf '%s\n' "$sha" | tr '[:upper:]' '[:lower:]'
}

# Extract the bare version (e.g. 1.22.0, 1.23rc1) that a `go` binary reports.
# The parse lives here once so the rc/beta regex cannot drift between callers.
_gos_go_version_of() {
  local go_bin="$1"
  "$go_bin" version 2>/dev/null \
    | grep -Eo 'go[0-9]+\.[0-9]+(\.[0-9]+)?(rc[0-9]+|beta[0-9]+)?' \
    | head -1 | sed 's/^go//'
}

_gos_current() {
  local version=""
  # A broken go binary (wrong arch, corrupt install) must not abort gos under
  # set -e: gos latest exists precisely to repair such installations.
  if command -v go &>/dev/null; then
    version=$(_gos_go_version_of go) || version=""
  fi

  if [ -n "$version" ]; then
    printf '%s\n' "$version"
  else
    echo "none"
  fi
}

# True when the requested version is genuinely served by the managed install:
# either PATH's go resolves from inside GOS_INSTALL_DIR, or GOS_INSTALL_DIR's
# own go reports that version. Prevents a matching go elsewhere on PATH
# (e.g. Homebrew's) from masking a missing or stale managed install.
_gos_active_install_matches() {
  local version="$1" go_path installed_go installed_version

  go_path=$(command -v go 2>/dev/null) || go_path=""
  case "$go_path" in
    "${GOS_INSTALL_DIR}/"*) return 0 ;;
  esac

  installed_go="${GOS_INSTALL_DIR}/bin/go"
  [ -x "$installed_go" ] || return 1
  installed_version=$(_gos_go_version_of "$installed_go") || installed_version=""
  [ "$installed_version" = "$version" ]
}

_gos_existing_parent_for() {
  local dir="$1" parent
  parent=$(dirname "$dir")

  while [ ! -d "$parent" ] && [ "$parent" != "/" ]; do
    parent=$(dirname "$parent")
  done

  printf '%s\n' "$parent"
}

# Determine if sudo is needed for operations under GOS_INSTALL_DIR's parent.
_gos_needs_sudo() {
  # Never use sudo on Windows
  if [ "$(_gos_os)" = "windows" ]; then
    return 1
  fi

  local parent
  parent=$(_gos_existing_parent_for "$GOS_INSTALL_DIR")
  if [ -w "$parent" ]; then
    return 1
  fi

  return 0
}

# Run a command with sudo only if needed. The command's stdout and stderr are
# kept separate so tool warnings never leak into data output.
_gos_sudo() {
  local output status err err_file sudo_output sudo_status sudo_err

  if _gos_needs_sudo; then
    sudo "$@"
    return
  fi

  err_file=$(mktemp) || {
    # No temp file for stderr capture; run the command directly.
    LC_ALL=C "$@"
    return
  }

  # LC_ALL=C keeps failure messages in English so the permission-error
  # detection below works regardless of the user's locale.
  set +e
  output=$(LC_ALL=C "$@" 2>"$err_file")
  status=$?
  set -e
  err=$(<"$err_file")

  if [ "$status" -eq 0 ]; then
    rm -f "$err_file"
    if [ -n "$output" ]; then
      printf '%s' "$output"
    fi
    if [ -n "$err" ]; then
      printf '%s' "$err" >&2
    fi
    return 0
  fi

  # Some environments (notably Git Bash on Windows) can report the install parent as
  # writable even when operations like sibling renames fail with a permissions error.
  # Retry with sudo when available and the error looks permission-related.
  if [ "$(_gos_os)" != "windows" ] && command -v sudo &>/dev/null; then
    case "${err}${output}" in
      *"Permission denied"*|*"permission denied"*|*"Operation not permitted"*|*"operation not permitted"*|*"Access is denied"*|*"access denied"*)
        set +e
        sudo_output=$(LC_ALL=C sudo "$@" 2>"$err_file")
        sudo_status=$?
        set -e
        sudo_err=$(<"$err_file")
        rm -f "$err_file"
        if [ "$sudo_status" -eq 0 ]; then
          if [ -n "$sudo_output" ]; then
            printf '%s' "$sudo_output"
          fi
          if [ -n "$sudo_err" ]; then
            printf '%s' "$sudo_err" >&2
          fi
          return 0
        fi
        printf '%s' "$err" >&2
        if [ -n "$sudo_err" ]; then
          printf '%s' "$sudo_err" >&2
        fi
        return "$sudo_status"
        ;;
    esac
  fi

  rm -f "$err_file"
  if [ -n "$output" ]; then
    printf '%s' "$output"
  fi
  printf '%s' "$err" >&2
  return "$status"
}

_gos_lock_dir() {
  printf '%s.gos-lock' "$GOS_INSTALL_DIR"
}

_gos_pid_is_running() {
  local pid="$1"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

_gos_report_existing_lock() {
  local lock_dir="$1" pid=""
  [ -f "${lock_dir}/pid" ] && pid=$(sed -n '1p' "${lock_dir}/pid" 2>/dev/null || true)

  if _gos_pid_is_running "$pid"; then
    echo "Error: another gos operation is running (pid ${pid})." >&2
    echo "Lock: ${lock_dir}" >&2
    return 1
  fi

  echo "Error: stale gos lock found at ${lock_dir}." >&2
  if [ -n "$pid" ]; then
    echo "The recorded pid (${pid}) is not running." >&2
  fi
  echo "Remove it manually if no gos install/update is active: rm -rf \"${lock_dir}\"" >&2
  return 1
}

_gos_acquire_lock() {
  local lock_dir lock_parent pid_file
  lock_dir=$(_gos_lock_dir)
  lock_parent=$(dirname "$lock_dir")
  pid_file="${lock_dir}/pid"

  if [ -n "$GOS_LOCK_DIR" ]; then
    return 0
  fi

  if [ ! -d "$lock_parent" ] && ! _gos_ensure_dir "$lock_parent"; then
    echo "Error: failed to create parent directory for GOS_INSTALL_DIR: ${lock_parent}" >&2
    return 1
  fi

  if mkdir "$lock_dir" 2>/dev/null; then
    :
  elif [ -d "$lock_dir" ]; then
    _gos_report_existing_lock "$lock_dir"
    return 1
  elif _gos_sudo mkdir "$lock_dir" 2>/dev/null; then
    :
  elif [ -d "$lock_dir" ]; then
    _gos_report_existing_lock "$lock_dir"
    return 1
  else
    echo "Error: could not create gos lock at ${lock_dir}." >&2
    return 1
  fi

  GOS_LOCK_DIR="$lock_dir"
  if ! printf '%s\n' "$$" >"$pid_file" 2>/dev/null; then
    if [ "$(_gos_os)" != "windows" ] && command -v sudo &>/dev/null; then
      printf '%s\n' "$$" | sudo tee "$pid_file" >/dev/null 2>&1 || true
    fi
  fi
}

# Create a directory, escalating to sudo only when the plain mkdir fails. One
# place for the mkdir-with-escalation policy so callers cannot drift.
_gos_ensure_dir() {
  local dir="$1"
  [ -d "$dir" ] && return 0
  mkdir -p "$dir" 2>/dev/null && return 0
  _gos_sudo mkdir -p "$dir" && return 0
  return 1
}

_gos_prepare_install_parent() {
  local parent
  parent=$(dirname "$GOS_INSTALL_DIR")

  if ! _gos_ensure_dir "$parent"; then
    echo "Error: failed to create parent directory for GOS_INSTALL_DIR: ${parent}" >&2
    return 1
  fi
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

  # -L so a side-by-side symlink backup is restored too; -d alone would silently
  # drop it and leave the install slot empty.
  if [ -n "$backup_dir" ] && { [ -e "$backup_dir" ] || [ -L "$backup_dir" ]; }; then
    _gos_sudo mv "$backup_dir" "$GOS_INSTALL_DIR" || return 1
  fi
}

_gos_rollback_dir() {
  printf '%s.gos-rollback' "$GOS_INSTALL_DIR"
}

_gos_warn_rollback_unavailable() {
  local backup_dir="$1" rollback_dir="$2"

  echo "Warning: rollback was not saved automatically." >&2
  echo "Warning: previous Go installation remains at: ${backup_dir}" >&2
  echo "Warning: to enable rollback manually, run: sudo mv \"${backup_dir}\" \"${rollback_dir}\"" >&2
}

_gos_save_rollback_backup() {
  local backup_dir="$1" rollback_dir
  rollback_dir=$(_gos_rollback_dir)

  # -L catches a dangling rollback symlink left after uninstalling the version
  # it pointed at; without removing that path first, the mv below fails and the
  # otherwise-good backup is stranded outside the rollback slot.
  if { [ -e "$rollback_dir" ] || [ -L "$rollback_dir" ]; } && ! _gos_sudo rm -rf "$rollback_dir"; then
    echo "Warning: failed to remove existing rollback installation at ${rollback_dir}." >&2
    _gos_warn_rollback_unavailable "$backup_dir" "$rollback_dir"
    return 0
  fi

  if ! _gos_sudo mv "$backup_dir" "$rollback_dir"; then
    echo "Warning: failed to save rollback installation at ${rollback_dir}." >&2
    _gos_warn_rollback_unavailable "$backup_dir" "$rollback_dir"
    return 0
  fi

  echo "Rollback available: gos rollback"
}

# Activate a new Go installation transactionally: back up whatever occupies
# GOS_INSTALL_DIR, put the new tree in place, validate it runs, and either save
# the displaced install for rollback or restore it on any failure. The single
# activation step differs by mode:
#   move  — rename a staged directory into place (flat layout)
#   link  — symlink GOS_INSTALL_DIR at a version directory (side-by-side layout)
# Both share the exact same crash-safety flow so it can never drift between them.
_gos_activate_install() {
  local activate_kind="$1" source="$2"
  local backup_dir="" version_output go_bin

  # -L also catches a (possibly dangling) side-by-side symlink; without it the
  # activation below fails with ENOTDIR when the slot is a symlink, not the empty
  # path a plain [ -e ] test assumes.
  if [ -e "$GOS_INSTALL_DIR" ] || [ -L "$GOS_INSTALL_DIR" ]; then
    backup_dir="${GOS_INSTALL_DIR}.gos-backup.$$"
    if [ -e "$backup_dir" ] || [ -L "$backup_dir" ]; then
      echo "Error: backup path already exists: ${backup_dir}" >&2
      return 1
    fi
    # Replacing one symlink with another is silent; a real install is not.
    if [ ! -L "$GOS_INSTALL_DIR" ]; then
      echo "Backing up existing Go installation..."
    fi
    # Moving a symlink moves the link itself, so the previous target survives.
    _gos_sudo mv "$GOS_INSTALL_DIR" "$backup_dir" || return 1
    GOS_ACTIVATION_BACKUP="$backup_dir"
  fi

  if [ "$activate_kind" = "link" ]; then
    echo "Activating go from ${source}..."
    if ! _gos_sudo ln -s "$source" "$GOS_INSTALL_DIR"; then
      echo "Error: failed to link new Go installation into place." >&2
      _gos_restore_backup "$backup_dir" || true
      GOS_ACTIVATION_BACKUP=""
      return 1
    fi
  else
    echo "Activating new Go installation..."
    if ! _gos_sudo mv "$source" "$GOS_INSTALL_DIR"; then
      echo "Error: failed to move new Go installation into place." >&2
      _gos_restore_backup "$backup_dir" || true
      GOS_ACTIVATION_BACKUP=""
      return 1
    fi
  fi
  # Keep GOS_ACTIVATION_BACKUP armed through validation: a validation-failure
  # restore below deletes GOS_INSTALL_DIR before moving the backup back, so if it
  # is interrupted (Ctrl-C between its rm and mv) the EXIT trap is the only thing
  # that can put the previous install back. Clearing it here would disarm that.
  go_bin="${GOS_INSTALL_DIR}/bin/go"
  if [ ! -x "$go_bin" ]; then
    echo "Error: activated Go installation is missing bin/go." >&2
    _gos_restore_backup "$backup_dir" || true
    GOS_ACTIVATION_BACKUP=""
    return 1
  fi

  if ! version_output=$("$go_bin" version 2>&1); then
    echo "Error: activated Go failed validation: ${version_output}" >&2
    _gos_restore_backup "$backup_dir" || true
    GOS_ACTIVATION_BACKUP=""
    return 1
  fi

  if [ -n "$backup_dir" ]; then
    _gos_save_rollback_backup "$backup_dir"
  fi
  # The new install is validated and in place and the backup has been consumed
  # (saved as rollback or restored); the trap no longer needs to act.
  GOS_ACTIVATION_BACKUP=""

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

  # -L also moves a (possibly dangling) side-by-side symlink out of the way;
  # otherwise the restore mv below fails because the slot is still occupied.
  if [ -e "$GOS_INSTALL_DIR" ] || [ -L "$GOS_INSTALL_DIR" ]; then
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
  local os arch ext pkg url tmp_dir tmp_file stage_dir staged_go_dir version_dir

  _gos_validate_version "$version" || return 1

  # Side-by-side fast path: the requested version is already installed, so
  # switching is just a symlink flip — no network, no extraction.
  if _gos_versions_mode; then
    _gos_validate_versions_dir || return 1
    version_dir=$(_gos_version_dir_for "$version")
    if [ -x "${version_dir}/bin/go" ]; then
      echo "Using installed go${version} from ${version_dir}."
      _gos_prepare_install_parent || return 1
      _gos_activate_install link "$version_dir" || return 1
      return 0
    fi
  fi

  os=$(_gos_os)
  arch=$(_gos_arch)
  ext=$(_gos_ext)

  if [ "$os" = "unsupported" ] || [ "$arch" = "unsupported" ]; then
    echo "Error: unsupported OS or architecture: detected $(uname -s)/$(uname -m) (mapped to ${os}/${arch})." >&2
    return 1
  fi

  _gos_validate_mirror || return 1

  pkg="go${version}.${os}-${arch}.${ext}"
  url="$(_gos_archive_base_url)/${pkg}"

  # Use a unique temp directory to prevent symlink/TOCTOU attacks.
  # The EXIT/INT/TERM trap removes it on every exit path.
  tmp_dir=$(mktemp -d) || { echo "Error: failed to create temp directory." >&2; return 1; }
  GOS_TMP_DIR="$tmp_dir"
  tmp_file="${tmp_dir}/${pkg}"
  stage_dir="${tmp_dir}/stage"
  staged_go_dir="${stage_dir}/go"

  # Resolve checksum metadata before consulting the local archive cache.
  # The feed cache is warmed here, in the parent shell, so the command
  # substitution below reuses it instead of re-downloading the feed.
  local expected_sha actual_sha cache_hit sha_source
  expected_sha=""
  sha_source=""
  if _gos_has_checksum_parser && _gos_feed_json "$include_all_checksums" >/dev/null; then
    expected_sha=$(_gos_fetch_checksum "$pkg" "$include_all_checksums") || expected_sha=""
    [ -n "$expected_sha" ] && sha_source="feed"
  fi
  if _gos_require_feed_checksum && [ "$sha_source" != "feed" ]; then
    echo "Error: GOS_REQUIRE_CHECKSUM=feed but no checksum was found in the go.dev downloads feed for ${pkg}." >&2
    echo "Install jq or python3 so feed metadata can be parsed, or use GOS_REQUIRE_CHECKSUM=1 to accept the .sha256 fallback." >&2
    return 1
  fi
  if [ -z "$expected_sha" ]; then
    expected_sha=$(_gos_fetch_checksum_file "$pkg") || expected_sha=""
    [ -n "$expected_sha" ] && sha_source="file"
  fi
  # Mirror downloads are only trusted when they can be verified against the
  # official go.dev checksum metadata; never fall back to unverified bytes.
  if [ -n "$GOS_DOWNLOAD_MIRROR" ] && [ -z "$expected_sha" ]; then
    echo "Error: GOS_DOWNLOAD_MIRROR is set but no official checksum is available for ${pkg}." >&2
    echo "Refusing to download unverifiable bytes from a mirror. Install jq or python3, or unset GOS_DOWNLOAD_MIRROR." >&2
    return 1
  fi
  cache_hit="false"

  if _gos_try_cache "$pkg" "$tmp_file" "$expected_sha"; then
    cache_hit="true"
  else
    echo "Downloading ${pkg}..."
    _gos_download "$url" "$tmp_file" || {
      echo "Error: download failed. Version '${version}' may not exist." >&2
      return 1
    }
  fi

  # Verify checksum if tools are available.
  if [ -n "$expected_sha" ]; then
    actual_sha=$(_gos_sha256 "$tmp_file")
    if [ -z "$actual_sha" ]; then
      if [ -n "$GOS_DOWNLOAD_MIRROR" ]; then
        echo "Error: GOS_DOWNLOAD_MIRROR is set but no SHA256 tool is available to verify ${pkg}." >&2
        echo "Install sha256sum or shasum, or unset GOS_DOWNLOAD_MIRROR." >&2
        return 1
      fi
      _gos_checksum_unavailable "no SHA256 tool output was available" || return 1
    elif [ "$actual_sha" != "$expected_sha" ]; then
      echo "Error: checksum mismatch! Expected ${expected_sha}, got ${actual_sha}." >&2
      echo "The download may be corrupted. Aborting." >&2
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
      reason="no checksum source was available (jq/python3 missing and the ${pkg}.sha256 lookup failed)"
    fi
    _gos_checksum_unavailable "$reason" || return 1
  fi

  echo "Extracting..."
  mkdir -p "$stage_dir"
  if ! _gos_extract_archive "$ext" "$tmp_file" "$stage_dir"; then
    echo "Error: extraction failed." >&2
    return 1
  fi

  _gos_validate_staged_install "$staged_go_dir" || return 1

  _gos_prepare_install_parent || return 1

  if _gos_versions_mode; then
    version_dir=$(_gos_version_dir_for "$version")
    if ! _gos_ensure_dir "$GOS_VERSIONS_DIR"; then
      echo "Error: failed to create GOS_VERSIONS_DIR: ${GOS_VERSIONS_DIR}" >&2
      return 1
    fi
    # A partial or broken previous copy (no executable bin/go) is replaced.
    if [ -e "$version_dir" ] && ! _gos_sudo rm -rf "$version_dir"; then
      echo "Error: failed to replace existing ${version_dir}." >&2
      return 1
    fi
    if ! _gos_sudo mv "$staged_go_dir" "$version_dir"; then
      echo "Error: failed to move new Go installation into ${GOS_VERSIONS_DIR}." >&2
      return 1
    fi
    _gos_activate_install link "$version_dir" || return 1
  else
    _gos_warn_orphaned_versions_link
    _gos_activate_install move "$staged_go_dir" || return 1
  fi

  rm -rf "$tmp_dir"
  GOS_TMP_DIR=""
}

_gos_find_upward() {
  local start_dir="$1" filename="$2" dir candidate
  dir=$(cd "$start_dir" 2>/dev/null && pwd) || return 1

  # The loop body runs for "/" too, so a manifest at the filesystem root is
  # still found.
  while :; do
    candidate="${dir%/}/${filename}"
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    [ "$dir" = "/" ] && break
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

_gos_read_tool_versions_file() {
  local file="$1" line tool version
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$line" ] && continue

    # shellcheck disable=SC2086 # Intentional field split: .tool-versions is whitespace-delimited.
    set -- $line
    tool="${1:-}"
    version="${2:-}"
    case "$tool" in
      go|golang)
        [ -n "$version" ] || continue
        version="${version#go}"
        printf '%s\n' "$version"
        return 0
        ;;
    esac
  done < "$file"
  return 1
}

# Resolve the Go version requested by a go.mod. Precedence mirrors the Go
# toolchain itself: an explicit `toolchain goX.Y.Z` directive wins over the
# `go X.Y` language directive; only the first `go` directive is considered.
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
  local start_dir="$1" dir candidate version

  dir=$(cd "$start_dir" 2>/dev/null && pwd) || return 1

  while :; do
    candidate="${dir%/}/.go-version"
    if [ -f "$candidate" ]; then
      version=$(_gos_read_go_version_file "$candidate") || return 1
      printf '%s|%s\n' "$version" "$candidate"
      return 0
    fi

    candidate="${dir%/}/.tool-versions"
    if [ -f "$candidate" ]; then
      version=$(_gos_read_tool_versions_file "$candidate") || return 1
      printf '%s|%s\n' "$version" "$candidate"
      return 0
    fi

    candidate="${dir%/}/go.mod"
    if [ -f "$candidate" ]; then
      version=$(_gos_read_go_mod_version "$candidate") || return 1
      printf '%s|%s\n' "$version" "$candidate"
      return 0
    fi

    [ "$dir" = "/" ] && break
    dir=$(dirname "$dir")
  done

  return 1
}

# Sort bare version numbers semantically: beta < rc < release, and pre-releases
# sort before the final release of the same minor (1.24rc2 < 1.24.0). A plain
# `sort -t. -kN,Nn` treats 1.24rc2 as 1.24, interleaving pre-releases wrongly.
_gos_sort_versions() {
  awk '
    {
      v = $0
      major = v
      sub(/\..*$/, "", major)
      rest = substr(v, length(major) + 2)
      rank = 2
      pre = 0
      if (match(rest, /beta[0-9]+$/)) {
        rank = 0
        pre = substr(rest, RSTART + 4) + 0
        rest = substr(rest, 1, RSTART - 1)
      } else if (match(rest, /rc[0-9]+$/)) {
        rank = 1
        pre = substr(rest, RSTART + 2) + 0
        rest = substr(rest, 1, RSTART - 1)
      }
      n = split(rest, parts, ".")
      minor = (n >= 1) ? parts[1] + 0 : 0
      patch = (n >= 2) ? parts[2] + 0 : 0
      printf "%d %d %d %d %d %s\n", major, minor, patch, rank, pre, v
    }
  ' \
    | sort -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n \
    | cut -d' ' -f6
}

_gos_list_versions() {
  local json
  json=$(_gos_feed_json true true) || {
    echo "Error: could not fetch the Go version list. Check your internet connection." >&2
    return 1
  }

  _gos_feed_versions "$json" \
    | _gos_sort_versions \
    | uniq \
    | sed 's/^/go/'
}

_gos_platforms_for_version() {
  local version="$1" json go_version
  go_version="go${version#go}"
  json=$(_gos_feed_json true true) || {
    echo "Error: could not fetch the Go downloads feed. Check your internet connection." >&2
    return 1
  }

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
            platforms.add(f"{file.get(\"os\")}/{file.get(\"arch\")}")
for platform in sorted(platforms):
    print(platform)
' "$go_version"
  else
    # Filter the scraped filenames to plain os/arch pairs: non-archive entries
    # (go1.x.src.tar.gz) pass through the sed unchanged and must not leak into
    # the output as bogus platforms.
    echo "$json" \
      | grep -o "${go_version}\\.[^\"]*" \
      | sed -E "s/^${go_version//./\\.}\\.([^-]+)-([^.]*)\\..*/\\1\\/\\2/" \
      | grep -E '^[a-z0-9]+/[a-z0-9]+$' \
      | sort -u
  fi
}

_gos_json_array_from_lines() {
  local first="true" line
  printf '['
  while IFS= read -r line; do
    line=${line%$'\r'}
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

_gos_path_is_under() {
  local path="$1" dir="$2"
  dir="${dir%/}"
  case "$path" in
    "$dir"|"$dir"/*) return 0 ;;
    *) return 1 ;;
  esac
}

_gos_active_go_path() {
  command -v go 2>/dev/null || return 1
}

_gos_cache_archive_stats() {
  local file count=0 bytes=0 size

  if [ -d "$GOS_CACHE_DIR" ]; then
    for file in "$GOS_CACHE_DIR"/go*.tar.gz "$GOS_CACHE_DIR"/go*.zip; do
      [ -f "$file" ] || continue
      count=$((count + 1))
      size=$(wc -c < "$file" | tr -d '[:space:]') || size=0
      bytes=$((bytes + size))
    done
  fi

  printf '%s|%s\n' "$count" "$bytes"
}

# ─── Commands ─────────────────────────────────────────────────────────────────

cmd_latest() {
  if [ "$#" -gt 0 ]; then
    echo "Error: unexpected argument for gos latest: ${1}" >&2
    echo "Usage: gos latest" >&2
    return 1
  fi

  echo "Fetching latest stable Go version..."
  local latest current

  # Warm the default-feed cache in the parent shell so the version lookup and
  # the checksum lookup share one network request.
  _gos_feed_json false >/dev/null || true

  latest=$(_gos_fetch_latest) || latest=""
  if [ -z "$latest" ]; then
    echo "Error: could not fetch latest version. Check your internet connection." >&2
    return 1
  fi

  current=$(_gos_current)
  echo "Latest: go${latest}"

  if [ "$current" = "$latest" ]; then
    if _gos_active_install_matches "$latest"; then
      echo "Already on Go ${latest}, nothing to do."
      return 0
    fi
    echo "Go ${latest} is active on PATH, but ${GOS_INSTALL_DIR} does not provide it; installing."
  fi

  if [ "$current" = "none" ]; then
    echo "Current: none -> go${latest}"
  else
    echo "Current: go${current} -> go${latest}"
  fi
  _gos_install_version "$latest"
}

cmd_check() {
  local latest current up_to_date
  _gos_set_json_from_args "$@" || return 1

  if ! _gos_json_enabled; then
    echo "Checking for Go updates..."
  fi

  latest=$(_gos_fetch_latest true) || latest=""
  if [ -z "$latest" ]; then
    echo "Error: could not fetch latest version. Check your internet connection." >&2
    return 1
  fi

  current=$(_gos_current)
  if [ "$current" = "$latest" ]; then
    up_to_date="true"
  else
    up_to_date="false"
  fi

  if _gos_json_enabled; then
    printf '{"current":'
    if [ "$current" = "none" ]; then
      printf 'null'
    else
      _gos_json_string "go${current}"
    fi
    printf ',"latest":'
    _gos_json_string "go${latest}"
    printf ',"up_to_date":%s}\n' "$up_to_date"
    return 0
  fi

  echo "Latest:  go${latest}"
  if [ "$current" = "none" ]; then
    echo "Current: none (no Go installation found)"
    echo "Install it with: gos latest"
  elif [ "$up_to_date" = "true" ]; then
    echo "Current: go${current}"
    echo "Already up to date."
  else
    echo "Current: go${current}"
    echo "Update available. Install it with: gos latest"
  fi
}

cmd_install() {
  local version="${1:-}"
  if [ -z "$version" ]; then
    echo "Usage: gos install <version>  e.g. gos install 1.26.1" >&2
    return 1
  fi
  if [ "$#" -gt 1 ]; then
    echo "Error: unexpected argument for gos install: ${2}" >&2
    echo "Usage: gos install <version>  e.g. gos install 1.26.1" >&2
    return 1
  fi

  # Strip leading 'go' prefix if provided e.g. go1.26.1 -> 1.26.1
  version="${version#go}"

  _gos_validate_version "$version" || return 1

  # Only a bare X.Y needs resolution to the newest patch release. The warm and
  # the resolver are gated on that case for two reasons: warming the feed for an
  # already-satisfied specific version would reach the network before the
  # idempotent check below (which must stay offline), and warming in the parent
  # shell — not the resolver's command-substitution subshell — is what lets the
  # resolver and the install below share a single feed request.
  local resolved
  case "$version" in
    *rc*|*beta*|*.*.*) ;;
    *)
      _gos_feed_json true >/dev/null 2>&1 || true
      resolved=$(_gos_resolve_bare_minor "$version")
      if [ "$resolved" != "$version" ]; then
        echo "Resolved Go ${version} to go${resolved}."
        version="$resolved"
      fi
      ;;
  esac

  local current
  current=$(_gos_current)
  if [ "$current" = "$version" ]; then
    if _gos_active_install_matches "$version"; then
      echo "Already on Go ${version}, nothing to do."
      return 0
    fi
    echo "Go ${version} is active on PATH, but ${GOS_INSTALL_DIR} does not provide it; installing."
  fi

  _gos_install_version "$version" true
}

cmd_current() {
  local current
  _gos_set_json_from_args "$@" || return 1
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

# Bare version numbers of locally installed Go versions, one per line.
_gos_installed_versions() {
  local entry base version installed_go

  if _gos_versions_mode; then
    [ -d "$GOS_VERSIONS_DIR" ] || return 0
    for entry in "$GOS_VERSIONS_DIR"/go*/; do
      entry="${entry%/}"
      [ -x "${entry}/bin/go" ] || continue
      base="${entry##*/}"
      printf '%s\n' "${base#go}"
    done
    return 0
  fi

  installed_go="${GOS_INSTALL_DIR}/bin/go"
  if [ -x "$installed_go" ]; then
    version=$(_gos_go_version_of "$installed_go") || version=""
    [ -n "$version" ] && printf '%s\n' "$version"
  fi
  return 0
}

cmd___versions() {
  local include_remote_cached="false" arg json versions

  for arg in "$@"; do
    case "$arg" in
      --remote-cached) include_remote_cached="true" ;;
      *)
        echo "Error: unknown option for gos __versions: ${arg}" >&2
        echo "Usage: gos __versions [--remote-cached]" >&2
        return 1
        ;;
    esac
  done

  versions=$(
    {
      _gos_installed_versions
      if [ "$include_remote_cached" = "true" ] && json=$(_gos_cached_feed_json true 2>/dev/null); then
        _gos_feed_versions "$json"
      fi
    } | _gos_sort_versions | uniq
  )
  [ -n "$versions" ] && printf '%s\n' "$versions"
  return 0
}

cmd_list() {
  local versions installed="false" current arg
  for arg in "$@"; do
    case "$arg" in
      --json) GOS_OUTPUT_JSON=1 ;;
      --installed) installed="true" ;;
      *)
        echo "Error: unknown option for gos list: ${arg}" >&2
        echo "Usage: gos list [--installed] [--json]" >&2
        return 1
        ;;
    esac
  done

  if [ "$installed" = "true" ]; then
    versions=$(_gos_installed_versions | _gos_sort_versions | sed 's/^/go/')
    if _gos_json_enabled; then
      current=$(_gos_current)
      printf '{"installed":'
      printf '%s\n' "$versions" | _gos_json_array_from_lines
      printf ',"active":'
      if [ "$current" = "none" ]; then
        printf 'null'
      else
        _gos_json_string "go${current}"
      fi
      printf '}\n'
    elif [ -z "$versions" ]; then
      echo "No Go versions installed."
    else
      printf '%s\n' "$versions"
    fi
    return 0
  fi

  if _gos_json_enabled; then
    # Resolve the list before emitting JSON so failures never print a
    # truncated document.
    versions=$(_gos_list_versions) || return 1
    printf '{"versions":'
    printf '%s\n' "$versions" | _gos_json_array_from_lines
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
    else
      echo "Error: unexpected argument for gos platforms: ${arg}" >&2
      echo "Usage: gos platforms [version] [--json]" >&2
      return 1
    fi
  done

  if [ -z "$version" ]; then
    version=$(_gos_fetch_latest true) || version=""
    if [ -z "$version" ]; then
      echo "Error: could not fetch latest version. Check your internet connection." >&2
      return 1
    fi
  fi

  _gos_validate_version "$version" || return 1
  platforms=$(_gos_platforms_for_version "$version") || platforms=""

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

cmd_which() {
  local version="" arg go_path managed="false" version_dir

  for arg in "$@"; do
    case "$arg" in
      --json) GOS_OUTPUT_JSON=1 ;;
      *)
        if [ -z "$version" ]; then
          version="${arg#go}"
        else
          echo "Error: unexpected argument for gos which: ${arg}" >&2
          echo "Usage: gos which [version] [--json]" >&2
          return 1
        fi
        ;;
    esac
  done

  if [ -n "$version" ]; then
    _gos_validate_version "$version" || return 1
    if ! _gos_versions_mode; then
      echo "Error: gos which <version> requires side-by-side mode (set GOS_VERSIONS_DIR)." >&2
      return 1
    fi
    _gos_validate_versions_dir || return 1
    version_dir=$(_gos_version_dir_for "$version")
    go_path="${version_dir}/bin/go"
    if [ ! -x "$go_path" ]; then
      echo "Error: go${version} is not installed under ${GOS_VERSIONS_DIR}." >&2
      return 1
    fi
    managed="true"
  else
    if ! go_path=$(_gos_active_go_path); then
      echo "Error: no go binary found on PATH." >&2
      return 1
    fi
    if _gos_path_is_under "$go_path" "$GOS_INSTALL_DIR"; then
      managed="true"
    fi
  fi

  if _gos_json_enabled; then
    printf '{"path":'
    _gos_json_string "$go_path"
    printf ',"managed":%s,"install_dir":' "$managed"
    _gos_json_string "$GOS_INSTALL_DIR"
    if [ -n "$version" ]; then
      printf ',"version":'
      _gos_json_string "go${version}"
    fi
    printf '}\n'
    return 0
  fi

  printf '%s\n' "$go_path"
}

cmd_status() {
  local active go_path source layout layout_target resolved project_version project_source
  local project_matches="null" rollback_available="false" stats cache_count cache_bytes

  _gos_set_json_from_args "$@" || return 1

  active=$(_gos_current)
  go_path=$(_gos_active_go_path 2>/dev/null) || go_path=""
  source="none"
  if [ -n "$go_path" ]; then
    if _gos_path_is_under "$go_path" "$GOS_INSTALL_DIR"; then
      source="managed"
    else
      source="path"
    fi
  fi

  if _gos_versions_mode; then
    layout="side-by-side"
  else
    layout="flat"
  fi
  layout_target=""
  if [ -L "$GOS_INSTALL_DIR" ]; then
    layout_target=$(readlink "$GOS_INSTALL_DIR" 2>/dev/null || true)
    if ! _gos_versions_mode; then
      layout="symlink"
    fi
  fi

  resolved=$(_gos_resolve_project_version "$PWD" 2>/dev/null) || resolved=""
  project_version=""
  project_source=""
  if [ -n "$resolved" ]; then
    project_version="${resolved%%|*}"
    project_source="${resolved#*|}"
    project_version="${project_version#go}"
    if [ "$active" = "$project_version" ]; then
      project_matches="true"
    else
      project_matches="false"
    fi
  fi

  if [ -d "$(_gos_rollback_dir)" ] || [ -L "$(_gos_rollback_dir)" ]; then
    rollback_available="true"
  fi
  stats=$(_gos_cache_archive_stats)
  cache_count="${stats%%|*}"
  cache_bytes="${stats#*|}"

  if _gos_json_enabled; then
    printf '{"active":'
    if [ "$active" = "none" ]; then
      printf 'null'
    else
      _gos_json_string "go${active}"
    fi
    printf ',"source":'
    _gos_json_string "$source"
    printf ',"go_path":'
    if [ -n "$go_path" ]; then _gos_json_string "$go_path"; else printf 'null'; fi
    printf ',"install_dir":'
    _gos_json_string "$GOS_INSTALL_DIR"
    printf ',"layout":'
    _gos_json_string "$layout"
    printf ',"layout_target":'
    if [ -n "$layout_target" ]; then _gos_json_string "$layout_target"; else printf 'null'; fi
    printf ',"project":'
    if [ -n "$project_version" ]; then
      printf '{"version":'
      _gos_json_string "go${project_version}"
      printf ',"source":'
      _gos_json_string "$project_source"
      printf ',"matches_active":%s}' "$project_matches"
    else
      printf 'null'
    fi
    printf ',"rollback_available":%s,"cache":{"dir":' "$rollback_available"
    _gos_json_string "$GOS_CACHE_DIR"
    printf ',"archives":%s,"bytes":%s},"gos_version":' "$cache_count" "$cache_bytes"
    _gos_json_string "$GOS_VERSION"
    printf '}\n'
    return 0
  fi

  if [ "$active" = "none" ]; then
    printf 'Active:       none\n'
  else
    printf 'Active:       go%s\n' "$active"
  fi
  if [ -n "$go_path" ]; then
    printf 'Go path:      %s (%s)\n' "$go_path" "$source"
  else
    printf 'Go path:      not found on PATH\n'
  fi
  printf 'Install dir:  %s\n' "$GOS_INSTALL_DIR"
  if [ -n "$layout_target" ]; then
    printf 'Layout:       %s -> %s\n' "$layout" "$layout_target"
  else
    printf 'Layout:       %s\n' "$layout"
  fi
  if [ -n "$project_version" ]; then
    if [ "$project_matches" = "true" ]; then
      printf 'Project:      go%s (%s, matches active)\n' "$project_version" "$project_source"
    else
      printf 'Project:      go%s (%s, differs from active)\n' "$project_version" "$project_source"
    fi
  else
    printf 'Project:      none found from %s upward\n' "$PWD"
  fi
  if [ "$rollback_available" = "true" ]; then
    printf 'Rollback:     available\n'
  else
    printf 'Rollback:     unavailable\n'
  fi
  printf 'Cache:        %s archive(s), %s byte(s) in %s\n' "$cache_count" "$cache_bytes" "$GOS_CACHE_DIR"
  printf 'gos:          v%s\n' "$GOS_VERSION"
}

cmd_use() {
  local start_dir="${1:-$PWD}" resolved version source

  if [ "$#" -gt 1 ]; then
    echo "Error: unexpected argument for gos use: ${2}" >&2
    echo "Usage: gos use [path]" >&2
    return 1
  fi

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
  if [ "$#" -gt 1 ]; then
    echo "Error: unexpected argument for gos pin: ${2}" >&2
    echo "Usage: gos pin <version>  e.g. gos pin 1.24.0" >&2
    return 1
  fi

  version="${version#go}"
  _gos_validate_version "$version" || return 1
  printf '%s\n' "$version" > .go-version
  echo "Pinned Go ${version} in .go-version"
}

cmd_rollback() {
  if [ "$#" -gt 0 ]; then
    echo "Error: unexpected argument for gos rollback: ${1}" >&2
    echo "Usage: gos rollback" >&2
    return 1
  fi

  _gos_activate_rollback
}

cmd_uninstall() {
  local version="${1:-}" version_dir rollback_dir

  if [ -z "$version" ]; then
    echo "Usage: gos uninstall <version>  e.g. gos uninstall 1.24.0" >&2
    return 1
  fi
  if [ "$#" -gt 1 ]; then
    echo "Error: unexpected argument for gos uninstall: ${2}" >&2
    echo "Usage: gos uninstall <version>  e.g. gos uninstall 1.24.0" >&2
    return 1
  fi
  version="${version#go}"
  _gos_validate_version "$version" || return 1

  if ! _gos_versions_mode; then
    echo "Error: gos uninstall requires side-by-side mode (set GOS_VERSIONS_DIR)." >&2
    echo "In the classic layout there is only one install; replace it with gos install/latest." >&2
    return 1
  fi
  _gos_validate_versions_dir || return 1

  # A bare X.Y resolves to the matching installed patch release, mirroring
  # `gos install 1.21` (which installs the newest 1.21.x): resolve against
  # what is actually installed so uninstall stays network-free.
  case "$version" in
    *rc*|*beta*|*.*.*) ;;
    *)
      local installed match_count=0 resolved=""
      for installed in $(_gos_installed_versions); do
        case "$installed" in
          "$version"|"$version".*) resolved="$installed"; match_count=$((match_count + 1)) ;;
        esac
      done
      if [ "$match_count" -eq 1 ]; then
        version="$resolved"
      elif [ "$match_count" -gt 1 ]; then
        echo "Error: '${version}' matches multiple installed Go versions; re-run with an exact version:" >&2
        for installed in $(_gos_installed_versions); do
          case "$installed" in "$version"|"$version".*) echo "  go${installed}" >&2 ;; esac
        done
        return 1
      fi
      ;;
  esac

  version_dir=$(_gos_version_dir_for "$version")
  if [ ! -d "$version_dir" ]; then
    echo "Error: go${version} is not installed under ${GOS_VERSIONS_DIR}." >&2
    return 1
  fi

  # Compare by device+inode (-ef), not by readlink string: a differently spelled
  # but filesystem-equivalent path (case-insensitive FS, symlinked component)
  # would otherwise bypass the guard and delete the live Go.
  if [ "$GOS_INSTALL_DIR" -ef "$version_dir" ]; then
    echo "Error: go${version} is the active version. Switch to another version first." >&2
    return 1
  fi

  rollback_dir=$(_gos_rollback_dir)
  if [ -e "$rollback_dir" ] && [ "$rollback_dir" -ef "$version_dir" ]; then
    echo "Warning: the rollback link points at go${version}; gos rollback will not work until the next install." >&2
  fi

  _gos_sudo rm -rf "$version_dir" || return 1
  echo "Uninstalled go${version} from ${version_dir}."
}

# Single-quote a value so it is inert when the caller runs it through eval.
# Wrapping in single quotes neutralizes every shell metacharacter; an embedded
# single quote is closed, escaped, and reopened ('\''). This is what keeps
# `eval "$(gos env)"` safe when GOS_INSTALL_DIR contains shell metacharacters.
_gos_shquote_posix() {
  local s=${1//\'/\'\\\'\'}
  printf "'%s'" "$s"
}

# Single-quote a value for `gos env --fish | source`. Inside fish single quotes
# only backslash and the single quote itself are special.
_gos_shquote_fish() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\'/\\\'}
  printf "'%s'" "$s"
}

# Print the shell configuration needed to put the managed Go on PATH.
# Usage: eval "$(gos env)"    or    gos env --fish | source
cmd_env() {
  local arg shell_kind="posix" go_bin

  for arg in "$@"; do
    case "$arg" in
      --json) GOS_OUTPUT_JSON=1 ;;
      --fish) shell_kind="fish" ;;
      *)
        echo "Error: unknown option for gos env: ${arg}" >&2
        echo "Usage: gos env [--fish] [--json]" >&2
        return 1
        ;;
    esac
  done

  go_bin="${GOS_INSTALL_DIR}/bin"

  if _gos_json_enabled; then
    printf '{"install_dir":'
    _gos_json_string "$GOS_INSTALL_DIR"
    printf ',"bin_dir":'
    _gos_json_string "$go_bin"
    printf '}\n'
    return 0
  fi

  if [ "$shell_kind" = "fish" ]; then
    printf 'fish_add_path --path %s\n' "$(_gos_shquote_fish "$go_bin")"
  else
    # The path is single-quoted so any metacharacter is inert; $PATH is left
    # outside the quotes so the user's shell still expands it.
    # shellcheck disable=SC2016
    printf 'export PATH=%s:"$PATH"\n' "$(_gos_shquote_posix "$go_bin")"
  fi
}

# Resolve the on-disk path of the running script, following symlinks when the
# platform allows it (git-clone setups symlink gos -> gos.sh).
_gos_self_path() {
  # BASH_SOURCE[0] is unbound under `set -u` when gos runs from stdin
  # (curl ... | bash -s doctor), so default it and fail cleanly rather than
  # aborting with "unbound variable" and silently resolving to the caller's cwd.
  local src="${BASH_SOURCE[0]:-}"
  if [ -z "$src" ] || [ "$src" = "bash" ] || [ "$src" = "sh" ]; then
    return 1
  fi

  if command -v realpath &>/dev/null; then
    realpath "$src" 2>/dev/null && return 0
  fi

  # Fallback for platforms without realpath (older macOS): follow symlinks by
  # hand so the git-checkout / Homebrew guards inspect the real script's
  # directory, not the symlink's.
  local link
  while [ -L "$src" ]; do
    link=$(readlink "$src") || break
    case "$link" in
      /*) src="$link" ;;
      *)  src="$(dirname "$src")/${link}" ;;
    esac
  done

  printf '%s/%s\n' "$(cd "$(dirname "$src")" && pwd)" "$(basename "$src")"
}

cmd_self_update() {
  local script_path script_dir tmp_dir new_script checksums
  local expected_sha actual_sha new_version

  if [ "$#" -gt 0 ]; then
    echo "Error: unexpected argument for gos self-update: ${1}" >&2
    echo "Usage: gos self-update" >&2
    return 1
  fi

  script_path=$(_gos_self_path) || {
    echo "Error: could not resolve the path of the running gos script." >&2
    return 1
  }
  script_dir=$(dirname "$script_path")

  # Package-manager installs own this file; self-updating would fight them.
  case "$script_path" in
    */Cellar/*|*/homebrew/*|*/linuxbrew/*)
      echo "Error: this gos was installed with Homebrew. Update it with: brew upgrade gos" >&2
      return 1
      ;;
  esac
  if [ -e "${script_dir}/.git" ]; then
    echo "Error: this gos runs from a git checkout. Update it with: git -C '${script_dir}' pull" >&2
    return 1
  fi

  echo "Checking for the latest gos release..."
  tmp_dir=$(mktemp -d) || { echo "Error: failed to create temp directory." >&2; return 1; }
  GOS_TMP_DIR="$tmp_dir"
  new_script="${tmp_dir}/gos.sh"
  checksums="${tmp_dir}/checksums.txt"

  _gos_download "${GOS_RELEASE_BASE_URL}/gos.sh" "$new_script" || {
    echo "Error: could not download the latest gos release. Check your internet connection." >&2
    return 1
  }

  new_version=$(sed -n 's/^GOS_VERSION="\([^"]*\)"$/\1/p' "$new_script" | head -1)
  if [ -z "$new_version" ]; then
    echo "Error: the downloaded file does not look like a gos release. Aborting." >&2
    return 1
  fi

  if [ "$new_version" = "$GOS_VERSION" ]; then
    echo "Already on the latest gos (v${GOS_VERSION})."
    return 0
  fi

  # Verify against the checksum manifest published with the release. Unlike a
  # Go archive install (which may fall back to a warning), self-update replaces
  # the running script — often via sudo — so it always fails closed: an
  # unverifiable download is refused regardless of GOS_REQUIRE_CHECKSUM.
  expected_sha=""
  if _gos_download "${GOS_RELEASE_BASE_URL}/checksums.txt" "$checksums" 2>/dev/null; then
    # Accept both text-mode ("<hash>  gos.sh") and binary-mode ("<hash> *gos.sh")
    # sha256sum manifests so a future release format change cannot silently
    # blank out the digest and disable verification.
    expected_sha=$(awk '{ f=$2; sub(/^\*/, "", f); if (f == "gos.sh") { print $1; exit } }' "$checksums")
  fi
  if [ -z "$expected_sha" ]; then
    echo "Error: could not obtain the published checksum for gos.sh; refusing to self-update from an unverifiable download." >&2
    echo "The release checksums.txt manifest was missing or unreadable. Re-run the installer instead (see the README)." >&2
    return 1
  fi
  actual_sha=$(_gos_sha256 "$new_script")
  if [ -z "$actual_sha" ]; then
    echo "Error: no SHA256 tool is available to verify the downloaded gos release; refusing to self-update." >&2
    echo "Install sha256sum or shasum, or re-run the installer instead." >&2
    return 1
  fi
  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "Error: checksum mismatch for the downloaded gos release." >&2
    echo "Expected ${expected_sha}, got ${actual_sha}. Aborting." >&2
    return 1
  fi
  echo "Checksum verified."

  # A syntax check catches truncated or mangled downloads before activation.
  if ! bash -n "$new_script" 2>/dev/null; then
    echo "Error: the downloaded gos release failed a syntax check. Aborting." >&2
    return 1
  fi

  chmod +x "$new_script"
  # Renaming over the running script is safe: bash keeps reading the original
  # inode. Escalate to sudo only for a genuine permission error against the
  # target directory; for anything else (cross-device rename, read-only FS)
  # sudo would not help, so surface the real error instead of hiding it behind
  # a generic message. LC_ALL=C keeps the error text matchable across locales.
  local mv_err mv_status
  set +e
  mv_err=$(LC_ALL=C mv -f "$new_script" "$script_path" 2>&1)
  mv_status=$?
  set -e
  if [ "$mv_status" -ne 0 ]; then
    case "$mv_err" in
      *"Permission denied"*|*"permission denied"*|*"Operation not permitted"*|*"operation not permitted"*)
        if [ "$(_gos_os)" != "windows" ] && command -v sudo &>/dev/null; then
          if ! sudo mv -f "$new_script" "$script_path"; then
            echo "Error: failed to replace ${script_path} even with sudo." >&2
            return 1
          fi
        else
          echo "Error: failed to replace ${script_path}: ${mv_err}" >&2
          echo "Re-run the installer instead (see the README installation section)." >&2
          return 1
        fi
        ;;
      *)
        echo "Error: failed to replace ${script_path}: ${mv_err}" >&2
        echo "Re-run the installer instead (see the README installation section)." >&2
        return 1
        ;;
    esac
  fi

  echo "gos updated: v${GOS_VERSION} -> v${new_version}"
  rm -rf "$tmp_dir"
  GOS_TMP_DIR=""
}

cmd_prune() {
  local prune_rollback="false" arg rollback_dir removed=0 file rollback_state

  for arg in "$@"; do
    case "$arg" in
      --rollback) prune_rollback="true" ;;
      --json) GOS_OUTPUT_JSON=1 ;;
      *)
        echo "Error: unknown option for gos prune: ${arg}" >&2
        echo "Usage: gos prune [--rollback] [--json]" >&2
        return 1
        ;;
    esac
  done

  if [ "$prune_rollback" = "true" ]; then
    _gos_acquire_lock || return 1
  fi

  # Delete only files that look like cached Go archives. GOS_CACHE_DIR is
  # user-controlled, so prune never runs rm -rf against it.
  if [ -d "$GOS_CACHE_DIR" ]; then
    for file in "$GOS_CACHE_DIR"/go*.tar.gz "$GOS_CACHE_DIR"/go*.zip; do
      [ -f "$file" ] || continue
      rm -f "$file"
      removed=$((removed + 1))
    done
  fi
  if ! _gos_json_enabled; then
    if [ "$removed" -gt 0 ]; then
      echo "Removed ${removed} cached Go archive(s) from ${GOS_CACHE_DIR}."
    else
      echo "No cached Go archives found in ${GOS_CACHE_DIR}."
    fi
  fi

  rollback_dir=$(_gos_rollback_dir)
  rollback_state="none"
  if [ "$prune_rollback" = "true" ]; then
    if [ -d "$rollback_dir" ] || [ -L "$rollback_dir" ]; then
      _gos_sudo rm -rf "$rollback_dir" || return 1
      rollback_state="removed"
      _gos_json_enabled || echo "Removed rollback installation at ${rollback_dir}."
    else
      _gos_json_enabled || echo "No rollback installation found at ${rollback_dir}."
    fi
  elif [ -d "$rollback_dir" ] || [ -L "$rollback_dir" ]; then
    rollback_state="kept"
    _gos_json_enabled || echo "Rollback installation kept at ${rollback_dir} (remove it with: gos prune --rollback)."
  fi

  # Crash residue: interrupted activations can strand *.gos-backup.<pid> /
  # *.gos-current.<pid> siblings. Only remove them when the active install is
  # healthy (they may be the sole surviving copy otherwise), and only with
  # --rollback, which already means "discard my safety copies".
  local orphan orphans_removed=0 orphans_found=0
  for orphan in "${GOS_INSTALL_DIR}.gos-backup."* "${GOS_INSTALL_DIR}.gos-current."*; do
    # -L so a stranded side-by-side symlink backup is reported/removed too.
    [ -d "$orphan" ] || [ -L "$orphan" ] || continue
    orphans_found=$((orphans_found + 1))
    if [ "$prune_rollback" = "true" ] && [ -x "${GOS_INSTALL_DIR}/bin/go" ]; then
      _gos_sudo rm -rf "$orphan" || return 1
      orphans_removed=$((orphans_removed + 1))
      _gos_json_enabled || echo "Removed orphaned backup at ${orphan}."
    else
      _gos_json_enabled || echo "Orphaned backup found at ${orphan} (remove it with: gos prune --rollback)."
    fi
  done

  if _gos_json_enabled; then
    printf '{"removed_archives":%s,"cache_dir":' "$removed"
    _gos_json_string "$GOS_CACHE_DIR"
    printf ',"rollback":'
    _gos_json_string "$rollback_state"
    printf ',"orphaned_backups_found":%s,"orphaned_backups_removed":%s}\n' "$orphans_found" "$orphans_removed"
  fi
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
  parent=$(_gos_existing_parent_for "$dir")

  [ -w "$parent" ] && return 0
  [ "$(_gos_os)" != "windows" ] && command -v sudo &>/dev/null && return 0
  return 1
}

_gos_doctor_record_fix() {
  local item="$1"

  if [ -n "${GOS_DOCTOR_FIXED_JSON:-}" ]; then
    GOS_DOCTOR_FIXED_JSON="${GOS_DOCTOR_FIXED_JSON},"
  fi
  GOS_DOCTOR_FIXED_JSON="${GOS_DOCTOR_FIXED_JSON}$(_gos_json_string "$item")"
  GOS_DOCTOR_FIXED_LINES="${GOS_DOCTOR_FIXED_LINES}${item}"$'\n'
}

_gos_doctor_path_setup_line() {
  # shellcheck disable=SC2016 # The emitted line must leave $PATH for the user's shell.
  printf 'export PATH=%s:"$PATH"' "$(_gos_shquote_posix "${GOS_INSTALL_DIR}/bin")"
}

_gos_doctor_apply_fixes() {
  local install_parent path_setup
  install_parent=$(dirname "$GOS_INSTALL_DIR")

  if ! _gos_validate_install_dir "$GOS_INSTALL_DIR" >/dev/null 2>&1; then
    echo "Warning: GOS_INSTALL_DIR is invalid; not creating its parent." >&2
  elif [ ! -d "$install_parent" ]; then
    if _gos_ensure_dir "$install_parent"; then
      _gos_doctor_record_fix "created install parent: ${install_parent}"
    else
      echo "Warning: could not create install parent: ${install_parent}" >&2
    fi
  fi

  if [ ! -d "$GOS_CACHE_DIR" ]; then
    if mkdir -p "$GOS_CACHE_DIR" 2>/dev/null; then
      _gos_doctor_record_fix "created cache dir: ${GOS_CACHE_DIR}"
    else
      echo "Warning: could not create cache dir: ${GOS_CACHE_DIR}" >&2
    fi
  fi

  path_setup=$(_gos_doctor_path_setup_line)
  GOS_DOCTOR_PATH_SETUP="$path_setup"
}

cmd_doctor() {
  local os arch raw_os raw_arch install_error mirror_error versions_error go_path go_version go_bin arg doctor_fix="false"
  GOS_DOCTOR_PROBLEMS=0
  GOS_DOCTOR_WARNINGS=0
  GOS_DOCTOR_JSON_ITEMS=""
  GOS_DOCTOR_FIXED_JSON=""
  GOS_DOCTOR_FIXED_LINES=""
  GOS_DOCTOR_PATH_SETUP=""

  for arg in "$@"; do
    case "$arg" in
      --json) GOS_OUTPUT_JSON=1 ;;
      --fix) doctor_fix="true" ;;
      *)
        echo "Error: unexpected argument: ${arg}" >&2
        return 1
        ;;
    esac
  done

  if [ "$doctor_fix" = "true" ]; then
    _gos_doctor_apply_fixes
  fi

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
      "${go_bin}/go"|"${go_bin}/go.exe")
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

  if [ -n "$GOS_DOWNLOAD_MIRROR" ]; then
    if mirror_error=$(_gos_validate_mirror 2>&1); then
      _gos_doctor_check "ok" "mirror" "archive downloads use ${GOS_DOWNLOAD_MIRROR}"
    else
      _gos_doctor_check "problem" "mirror" "$mirror_error" "Set GOS_DOWNLOAD_MIRROR to an https:// URL or unset it."
    fi
  fi

  if _gos_versions_mode; then
    if versions_error=$(_gos_validate_versions_dir 2>&1); then
      _gos_doctor_check "ok" "versions-dir" "side-by-side installs under ${GOS_VERSIONS_DIR}"
    else
      _gos_doctor_check "problem" "versions-dir" "$versions_error" "Set GOS_VERSIONS_DIR to a safe absolute path or unset it."
    fi
  fi

  if _gos_has_checksum_parser; then
    _gos_doctor_check "ok" "checksum-metadata" "jq or python3 is available"
  elif _gos_require_checksum; then
    _gos_doctor_check "problem" "checksum-metadata" "GOS_REQUIRE_CHECKSUM=1 but jq/python3 is missing" "Install jq or python3."
  else
    _gos_doctor_check "warn" "checksum-metadata" "jq/python3 is missing; checksum metadata cannot be parsed"
  fi

  # Actually hash a throwaway file (not "$0", which is "bash" under curl | bash),
  # so a present-but-broken tool — a shasum missing a Perl module, a wrong-arch
  # binary — is caught here instead of only when an install later fails.
  local hash_probe hash_out
  hash_probe=$(mktemp 2>/dev/null) || hash_probe=""
  hash_out=""
  if [ -n "$hash_probe" ]; then
    printf 'gos' >"$hash_probe"
    hash_out=$(_gos_sha256 "$hash_probe")
    rm -f "$hash_probe"
  fi
  if [ "${#hash_out}" -eq 64 ]; then
    _gos_doctor_check "ok" "checksum-hash" "SHA256 hash tool is available"
  elif _gos_require_checksum; then
    _gos_doctor_check "problem" "checksum-hash" "GOS_REQUIRE_CHECKSUM=1 but no working SHA256 tool is available" "Install sha256sum or shasum."
  else
    _gos_doctor_check "warn" "checksum-hash" "no working SHA256 tool found; downloads cannot be locally hashed"
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

  local script_dir self_path
  # Resolve symlinks (a symlinked gos on PATH is common for git-clone
  # installs) so the completions check looks next to the real script.
  if self_path=$(_gos_self_path); then
    script_dir=$(dirname "$self_path")
    if [ -f "${script_dir}/completions/gos.bash" ] && [ -f "${script_dir}/completions/gos.zsh" ] && [ -f "${script_dir}/completions/gos.fish" ]; then
      _gos_doctor_check "ok" "completions" "Bash, Zsh, and Fish completion files are present"
    else
      _gos_doctor_check "warn" "completions" "one or more completion files are missing" "Run gos completions <bash|zsh|fish> to write or source an embedded completion script."
    fi
  else
    # No on-disk script path (e.g. run from stdin: curl ... | bash -s doctor).
    _gos_doctor_check "warn" "completions" "cannot locate the gos script on disk to check completions" "After installing gos, run gos completions <bash|zsh|fish> to write or source an embedded completion script."
  fi

  if _gos_json_enabled; then
    if [ "$GOS_DOCTOR_PROBLEMS" -gt 0 ]; then
      printf '{"status":"problem","problems":%s,"warnings":%s,"checks":[%s]' "$GOS_DOCTOR_PROBLEMS" "$GOS_DOCTOR_WARNINGS" "$GOS_DOCTOR_JSON_ITEMS"
    else
      printf '{"status":"ok","problems":0,"warnings":%s,"checks":[%s]' "$GOS_DOCTOR_WARNINGS" "$GOS_DOCTOR_JSON_ITEMS"
    fi
    if [ "$doctor_fix" = "true" ]; then
      printf ',"fixed":[%s],"path_setup":' "$GOS_DOCTOR_FIXED_JSON"
      _gos_json_string "$GOS_DOCTOR_PATH_SETUP"
    fi
    printf '}\n'
  elif [ "$doctor_fix" = "true" ]; then
    if [ -n "$GOS_DOCTOR_FIXED_LINES" ]; then
      while IFS= read -r arg; do
        [ -n "$arg" ] && printf 'fix - %s\n' "$arg"
      done <<EOF
$GOS_DOCTOR_FIXED_LINES
EOF
    else
      printf 'fix - no safe automatic fixes needed\n'
    fi
    printf 'fix - shell setup: %s\n' "$GOS_DOCTOR_PATH_SETUP"
  fi

  [ "$GOS_DOCTOR_PROBLEMS" -eq 0 ]
}

cmd_version() {
  _gos_set_json_from_args "$@" || return 1
  if _gos_json_enabled; then
    printf '{"gos_version":'
    _gos_json_string "$GOS_VERSION"
    printf '}\n'
    return 0
  fi

  echo "gos v${GOS_VERSION}"
}

# gos-completions:bash:begin
_gos_completion_bash() {
  cat <<'GOS_COMPLETION_BASH'
#!/usr/bin/env bash
# Bash completion for gos

_gos_completions() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local commands="latest install use pin check rollback uninstall prune current list platforms status which env completions doctor self-update version help"
  local cmd_index=1 cmd words="" line
  local versions=""

  # A leading --json shifts the command to the next position (gos --json list).
  if [ "${COMP_WORDS[1]:-}" = "--json" ]; then
    cmd_index=2
  fi

  COMPREPLY=()
  if [ "$COMP_CWORD" -le "$cmd_index" ]; then
    words="$commands"
    if [ "$cmd_index" -eq 1 ]; then
      words="$words --json"
    fi
  else
    cmd="${COMP_WORDS[$cmd_index]:-}"
    case "$cmd" in
      prune)
        words="--rollback --json"
        ;;
      install)
        if command -v gos >/dev/null 2>&1; then
          versions=$(gos __versions --remote-cached 2>/dev/null || true)
        fi
        words="$versions"
        ;;
      uninstall)
        if command -v gos >/dev/null 2>&1; then
          versions=$(gos __versions 2>/dev/null || true)
        fi
        words="$versions"
        ;;
      which)
        if command -v gos >/dev/null 2>&1; then
          versions=$(gos __versions 2>/dev/null || true)
        fi
        words="--json $versions"
        ;;
      list)
        words="--installed --json"
        ;;
      env)
        words="--fish --json"
        ;;
      completions)
        words="bash zsh fish"
        ;;
      doctor)
        words="--fix --json"
        ;;
      check|current|platforms|status|version)
        words="--json"
        ;;
      use)
        while IFS= read -r line; do
          COMPREPLY+=("$line")
        done < <(compgen -d -- "$cur")
        return
        ;;
      *)
        return
        ;;
    esac
  fi

  while IFS= read -r line; do
    COMPREPLY+=("$line")
  done < <(compgen -W "$words" -- "$cur")
}

complete -F _gos_completions gos
GOS_COMPLETION_BASH
}
# gos-completions:bash:end

# gos-completions:zsh:begin
_gos_completion_zsh() {
  cat <<'GOS_COMPLETION_ZSH'
#compdef gos
# Zsh completion for gos

_gos() {
  local context state state_descr line
  typeset -A opt_args
  local -a commands
  commands=(
    'latest:Install the latest stable Go version'
    'install:Install a specific Go version'
    'use:Install the Go version requested by project manifest'
    'pin:Write .go-version in the current directory'
    'check:Check whether a newer stable Go is available'
    'rollback:Restore the previous Go installation'
    'uninstall:Remove an installed version (side-by-side mode)'
    'prune:Remove cached Go archives and optionally the rollback copy'
    'current:Show the currently active Go version'
    'list:List available Go versions (or installed ones with --installed)'
    'platforms:List supported OS/arch archives for a Go version'
    'status:Show an offline dashboard for gos and the active Go'
    'which:Show the active or side-by-side Go binary path'
    'env:Print the PATH setup line for your shell'
    'completions:Print a Bash, Zsh, or Fish completion script'
    'doctor:Diagnose gos, Go, PATH, and tool dependencies'
    'self-update:Update gos itself to the latest release'
    'version:Show gos version'
    'help:Show help message'
  )

  _arguments '--json[Output machine-readable JSON where supported]' '1:command:->cmds' '*::arg:->args'

  case "$state" in
    cmds)
      _describe -t commands 'gos command' commands
      ;;
    args)
      case "${line[1]}" in
        prune)
          _arguments '--rollback[Also remove the rollback installation]' '--json[Output machine-readable JSON]'
          ;;
        install)
          if command -v gos >/dev/null 2>&1; then
            _values 'Go version' ${(f)"$(gos __versions --remote-cached 2>/dev/null)"}
          fi
          ;;
        uninstall)
          if command -v gos >/dev/null 2>&1; then
            _values 'Installed Go version' ${(f)"$(gos __versions 2>/dev/null)"}
          fi
          ;;
        which)
          _arguments '--json[Output machine-readable JSON]'
          if command -v gos >/dev/null 2>&1; then
            _values 'Installed Go version' ${(f)"$(gos __versions 2>/dev/null)"}
          fi
          ;;
        list)
          _arguments '--installed[List locally installed versions]' '--json[Output machine-readable JSON]'
          ;;
        env)
          _arguments '--fish[Emit fish shell syntax]' '--json[Output machine-readable JSON]'
          ;;
        completions)
          _values 'shell' bash zsh fish
          ;;
        doctor)
          _arguments '--fix[Apply safe non-destructive fixes]' '--json[Output machine-readable JSON]'
          ;;
        check|current|platforms|status|version)
          _arguments '--json[Output machine-readable JSON]'
          ;;
        use)
          _files -/
          ;;
      esac
      ;;
  esac
}

_gos "$@"
GOS_COMPLETION_ZSH
}
# gos-completions:zsh:end

# gos-completions:fish:begin
_gos_completion_fish() {
  cat <<'GOS_COMPLETION_FISH'
# Fish completion for gos

complete -c gos -f
complete -c gos -n '__fish_use_subcommand' -a 'latest'  -d 'Install the latest stable Go version'
complete -c gos -n '__fish_use_subcommand' -a 'install'  -d 'Install a specific Go version'
complete -c gos -n '__fish_use_subcommand' -a 'use'      -d 'Install the Go version requested by project manifest'
complete -c gos -n '__fish_use_subcommand' -a 'pin'      -d 'Write .go-version in the current directory'
complete -c gos -n '__fish_use_subcommand' -a 'check'    -d 'Check whether a newer stable Go is available'
complete -c gos -n '__fish_use_subcommand' -a 'rollback' -d 'Restore the previous Go installation'
complete -c gos -n '__fish_use_subcommand' -a 'uninstall' -d 'Remove an installed version (side-by-side mode)'
complete -c gos -n '__fish_use_subcommand' -a 'prune'    -d 'Remove cached Go archives and optionally the rollback copy'
complete -c gos -n '__fish_use_subcommand' -a 'current'  -d 'Show the currently active Go version'
complete -c gos -n '__fish_use_subcommand' -a 'list'     -d 'List all available Go versions'
complete -c gos -n '__fish_use_subcommand' -a 'platforms' -d 'List supported OS/arch archives for a Go version'
complete -c gos -n '__fish_use_subcommand' -a 'status'   -d 'Show an offline dashboard for gos and the active Go'
complete -c gos -n '__fish_use_subcommand' -a 'which'    -d 'Show the active or side-by-side Go binary path'
complete -c gos -n '__fish_use_subcommand' -a 'env'      -d 'Print the PATH setup line for your shell'
complete -c gos -n '__fish_use_subcommand' -a 'completions' -d 'Print a Bash, Zsh, or Fish completion script'
complete -c gos -n '__fish_use_subcommand' -a 'doctor'   -d 'Diagnose gos, Go, PATH, and tool dependencies'
complete -c gos -n '__fish_use_subcommand' -a 'self-update' -d 'Update gos itself to the latest release'
complete -c gos -n '__fish_use_subcommand' -a 'version'  -d 'Show gos version'
complete -c gos -n '__fish_use_subcommand' -a 'help'     -d 'Show help message'
# --json only where gos actually supports it (leading flag or per command).
complete -c gos -n '__fish_use_subcommand' -l json -d 'Output machine-readable JSON where supported'
complete -c gos -n '__fish_seen_subcommand_from check current list platforms status which doctor prune env version' -l json -d 'Output machine-readable JSON'
complete -c gos -n '__fish_seen_subcommand_from prune' -l rollback -d 'Also remove the rollback installation'
complete -c gos -n '__fish_seen_subcommand_from doctor' -l fix -d 'Apply safe non-destructive fixes'
complete -c gos -n '__fish_seen_subcommand_from list' -l installed -d 'List locally installed versions'
complete -c gos -n '__fish_seen_subcommand_from install' -a '(gos __versions --remote-cached 2>/dev/null)' -d 'Go version'
complete -c gos -n '__fish_seen_subcommand_from uninstall which' -a '(gos __versions 2>/dev/null)' -d 'Installed Go version'
complete -c gos -n '__fish_seen_subcommand_from env' -l fish -d 'Emit fish shell syntax'
complete -c gos -n '__fish_seen_subcommand_from use' -a '(__fish_complete_directories)' -d 'Project directory'
complete -c gos -n '__fish_seen_subcommand_from completions' -a 'bash zsh fish' -d 'Shell'
GOS_COMPLETION_FISH
}
# gos-completions:fish:end

cmd_completions() {
  local shell_name="${1:-}"

  if [ -z "$shell_name" ]; then
    echo "Usage: gos completions <bash|zsh|fish>" >&2
    return 1
  fi
  if [ "$#" -gt 1 ]; then
    echo "Error: unexpected argument for gos completions: ${2}" >&2
    echo "Usage: gos completions <bash|zsh|fish>" >&2
    return 1
  fi

  case "$shell_name" in
    bash) _gos_completion_bash ;;
    zsh)  _gos_completion_zsh ;;
    fish) _gos_completion_fish ;;
    *)
      echo "Error: unsupported shell for gos completions: ${shell_name}" >&2
      echo "Usage: gos completions <bash|zsh|fish>" >&2
      return 1
      ;;
  esac
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
  use [path]          Install the Go version requested by project manifest
  pin <version>       Write .go-version in the current directory
  check               Check whether a newer stable Go is available
  rollback            Restore the previous Go installation, if available
  uninstall <version> Remove an installed version (side-by-side mode only)
  prune [--rollback]  Remove cached Go archives (and the rollback copy with --rollback)
  current             Show the currently active Go version
  list [--installed]  List available Go versions (or locally installed ones)
  platforms [version] List supported OS/arch archives for a Go version
  status              Show an offline dashboard for gos and the active Go
  which [version]     Show the active or side-by-side Go binary path
  env [--fish]        Print the PATH setup line for your shell
  completions <shell> Print a Bash, Zsh, or Fish completion script
  doctor [--fix]      Diagnose gos, Go, PATH, and tool dependencies
  self-update         Update gos itself to the latest release
  version             Show gos version
  help                Show this help message

OPTIONS:
  --json              Machine-readable output for check, current, list,
                      platforms, status, which, env, doctor, prune, and version

EXAMPLES:
  gos latest
  gos install 1.24.0
  gos use
  gos pin 1.24.0
  gos check --json
  gos doctor --fix
  gos current
  gos list --json
  gos status
  gos which
  gos completions bash

EOF
}

_gos_commands() {
  printf '%s\n' \
    latest install use pin check rollback uninstall prune current list \
    platforms status which env completions doctor self-update version help
}

_gos_suggest_command() {
  local input="$1" command

  # Avoid noisy guesses for one- or two-letter typos. Prefix matching is
  # deterministic, offline, and cheap enough for the unknown-command path.
  [ "${#input}" -ge 3 ] || return 0

  _gos_commands | while IFS= read -r command; do
    case "$command" in
      "$input"*) printf '%s\n' "$command" ;;
    esac
  done
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
      _gos_acquire_lock || return 1
      cmd_latest "$@"
      ;;
    install)
      _gos_validate_install_dir "$GOS_INSTALL_DIR" || return 1
      _gos_acquire_lock || return 1
      cmd_install "$@"
      ;;
    use)
      _gos_validate_install_dir "$GOS_INSTALL_DIR" || return 1
      _gos_acquire_lock || return 1
      cmd_use "$@"
      ;;
    pin)       cmd_pin "$@" ;;
    rollback)
      _gos_validate_install_dir "$GOS_INSTALL_DIR" || return 1
      _gos_acquire_lock || return 1
      cmd_rollback "$@"
      ;;
    prune)
      _gos_validate_install_dir "$GOS_INSTALL_DIR" || return 1
      cmd_prune "$@"
      ;;
    check)     cmd_check "$@" ;;
    self-update|selfupdate) cmd_self_update "$@" ;;
    uninstall)
      _gos_validate_install_dir "$GOS_INSTALL_DIR" || return 1
      _gos_acquire_lock || return 1
      cmd_uninstall "$@"
      ;;
    env)
      _gos_validate_install_dir "$GOS_INSTALL_DIR" || return 1
      cmd_env "$@"
      ;;
    completions) cmd_completions "$@" ;;
    current)   cmd_current "$@" ;;
    list)      cmd_list "$@" ;;
    platforms) cmd_platforms "$@" ;;
    status)    cmd_status "$@" ;;
    which)     cmd_which "$@" ;;
    __versions) cmd___versions "$@" ;;
    doctor)    cmd_doctor "$@" ;;
    version)   cmd_version "$@" ;;
    help|--help|-h) cmd_help ;;
    *)
      local suggestion suggestions
      echo "Error: unknown command: $cmd" >&2
      suggestions=$(_gos_suggest_command "$cmd")
      if [ -n "$suggestions" ]; then
        echo "Did you mean?" >&2
        while IFS= read -r suggestion; do
          echo "  ${suggestion}" >&2
        done <<EOF
$suggestions
EOF
      fi
      cmd_help
      return 1
      ;;
  esac
}

main "$@"
