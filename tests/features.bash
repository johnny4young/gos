#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/gos.sh"
gos_version="$(sed -n 's/^GOS_VERSION="\([^"]*\)"$/\1/p' "$script")"
[ -n "$gos_version" ] || { echo "not ok - could not read GOS_VERSION from gos.sh" >&2; exit 1; }
test_root="$(mktemp -d)"
fake_bin="${test_root}/bin"
original_path="$PATH"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

mkdir -p "$fake_bin"

cat >"${fake_bin}/uname" <<'FAKE_UNAME'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  -s)
    [ "${GOS_TEST_UNSUPPORTED_PLATFORM:-}" = "1" ] && echo "Plan9" || echo "Darwin"
    ;;
  -m)
    [ "${GOS_TEST_UNSUPPORTED_PLATFORM:-}" = "1" ] && echo "mystery" || echo "arm64"
    ;;
  *)
    [ "${GOS_TEST_UNSUPPORTED_PLATFORM:-}" = "1" ] && echo "Plan9" || echo "Darwin"
    ;;
esac
FAKE_UNAME

cat >"${fake_bin}/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail

output=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    --proto|--connect-timeout|--retry)
      shift 2
      ;;
    --tlsv1.2|-fsSL)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

printf '%s\n' "$url" >>"$GOS_TEST_URL_LOG"

if [ "${GOS_TEST_DOWNLOAD_MODE:-ok}" = "fail-all" ]; then
  echo "curl: (6) Could not resolve host: go.dev" >&2
  exit 6
fi

case "$url" in
  https://mirror.test.invalid/dl/go*)
    if [ "${GOS_TEST_DOWNLOAD_MODE:-ok}" = "fail-archives" ]; then
      echo "archive download disabled" >&2
      exit 1
    fi
    printf 'fake archive for %s\n' "$url" >"$output"
    ;;
  https://github.com/johnny4young/gos/releases/latest/download/gos.sh)
    cat "$GOS_TEST_SELFUPDATE_SCRIPT" >"$output"
    ;;
  https://github.com/johnny4young/gos/releases/latest/download/checksums.txt)
    printf 'expectedsha  gos.sh\n' >"$output"
    ;;
  'https://go.dev/dl/?mode=json')
    cat <<'JSON'
[
  {
    "version": "go1.21.6",
    "files": [
      {"filename": "go1.21.6.darwin-arm64.tar.gz", "os": "darwin", "arch": "arm64", "kind": "archive", "sha256": "expectedsha"},
      {"filename": "go1.21.6.linux-amd64.tar.gz", "os": "linux", "arch": "amd64", "kind": "archive", "sha256": "linuxsha"}
    ]
  },
  {
    "version": "go1.20.0",
    "files": [
      {"filename": "go1.20.0.darwin-arm64.tar.gz", "os": "darwin", "arch": "arm64", "kind": "archive", "sha256": "oldsha"}
    ]
  }
]
JSON
    ;;
  'https://go.dev/dl/?mode=json&include=all')
    cat <<'JSON'
[
  {
    "version": "go1.22rc1",
    "files": []
  },
  {
    "version": "go1.21.6",
    "files": [
      {"filename": "go1.21.6.darwin-arm64.tar.gz", "os": "darwin", "arch": "arm64", "kind": "archive", "sha256": "expectedsha"},
      {"filename": "go1.21.6.linux-amd64.tar.gz", "os": "linux", "arch": "amd64", "kind": "archive", "sha256": "linuxsha"}
    ]
  },
  {
    "version": "go1.21rc1",
    "files": []
  },
  {
    "version": "go1.20.0",
    "files": [
      {"filename": "go1.20.0.darwin-arm64.tar.gz", "os": "darwin", "arch": "arm64", "kind": "archive", "sha256": "oldsha"}
    ]
  }
]
JSON
    ;;
  https://go.dev/dl/go*)
    if [ "${GOS_TEST_DOWNLOAD_MODE:-ok}" = "fail-archives" ]; then
      echo "archive download disabled" >&2
      exit 1
    fi
    printf 'fake archive for %s\n' "$url" >"$output"
    ;;
  https://dl.google.com/go/go*.sha256)
    # Companion checksum fallback is exercised in tests/checksum.bash.
    echo "404" >&2
    exit 22
    ;;
  *)
    echo "unexpected curl URL: $url" >&2
    exit 1
    ;;
esac
FAKE_CURL

cat >"${fake_bin}/sha256sum" <<'FAKE_SHA256SUM'
#!/usr/bin/env bash
set -euo pipefail

if grep -q GOS-TEST-CORRUPT "$1" 2>/dev/null; then
  printf 'corruptsha  %s\n' "$1"
  exit 0
fi

case "$1" in
  *go1.20.0.darwin-arm64.tar.gz)
    printf 'oldsha  %s\n' "$1"
    ;;
  *)
    printf 'expectedsha  %s\n' "$1"
    ;;
esac
FAKE_SHA256SUM

cat >"${fake_bin}/tar" <<'FAKE_TAR'
#!/usr/bin/env bash
set -euo pipefail

archive=""
stage_dir=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      stage_dir="$2"
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      archive="$1"
      shift
      ;;
  esac
done

version="1.21.6"
case "$archive" in
  *go1.20.0*) version="1.20.0" ;;
  *go1.21.6*) version="1.21.6" ;;
esac

mkdir -p "${stage_dir}/go/bin"
cat >"${stage_dir}/go/bin/go" <<FAKE_GO_BIN
#!/usr/bin/env bash
echo "go version go${version} darwin/arm64"
FAKE_GO_BIN
chmod +x "${stage_dir}/go/bin/go"
printf 'new-%s\n' "$version" >"${stage_dir}/go/VERSION_MARKER"
FAKE_TAR

cat >"${fake_bin}/go" <<'FAKE_GO'
#!/usr/bin/env bash
if [ "${GOS_TEST_GO_BROKEN:-0}" = "1" ]; then
  echo "go: exec format error" >&2
  exit 126
fi
echo "go version go${GOS_TEST_GO_VERSION:-1.20rc1} darwin/arm64"
FAKE_GO

chmod +x "${fake_bin}/uname" "${fake_bin}/curl" "${fake_bin}/sha256sum" \
  "${fake_bin}/tar" "${fake_bin}/go"

fail() {
  echo "not ok - $*" >&2
  exit 1
}

pass() {
  echo "ok - $*"
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "${name}: missing '${needle}'. Output: ${haystack}" ;;
  esac
}

run_gos() {
  local case_dir="$1"
  shift
  output=""
  status=0
  mkdir -p "$case_dir"
  : >"${case_dir}/urls.log"

  set +e
  output="$(
    PATH="${fake_bin}:${original_path}" \
    GOS_INSTALL_DIR="${GOS_TEST_INSTALL_DIR:-${case_dir}/go}" \
    GOS_CACHE_DIR="${case_dir}/cache" \
    GOS_DOWNLOAD_MIRROR="${GOS_TEST_MIRROR:-}" \
    GOS_VERSIONS_DIR="${GOS_TEST_VERSIONS_DIR:-}" \
    GOS_TEST_URL_LOG="${case_dir}/urls.log" \
    GOS_TEST_DOWNLOAD_MODE="${GOS_TEST_DOWNLOAD_MODE:-ok}" \
    GOS_TEST_UNSUPPORTED_PLATFORM="${GOS_TEST_UNSUPPORTED_PLATFORM:-0}" \
    GOS_TEST_GO_VERSION="${GOS_TEST_GO_VERSION:-}" \
    GOS_TEST_GO_BROKEN="${GOS_TEST_GO_BROKEN:-0}" \
    GOS_TEST_SELFUPDATE_SCRIPT="${GOS_TEST_SELFUPDATE_SCRIPT:-}" \
    "$@" 2>&1
  )"
  status=$?
  set -e
}

create_old_install() {
  local install_dir="$1" version="${2:-1.20.0}" marker="${3:-old}"
  mkdir -p "${install_dir}/bin"
  cat >"${install_dir}/bin/go" <<FAKE_INSTALLED_GO
#!/usr/bin/env bash
echo "go version go${version} darwin/arm64"
FAKE_INSTALLED_GO
  chmod +x "${install_dir}/bin/go"
  printf '%s\n' "$marker" >"${install_dir}/VERSION_MARKER"
}

case_dir="${test_root}/json"
run_gos "$case_dir" bash "$script" version --json
[ "$status" -eq 0 ] || fail "version --json failed: ${output}"
assert_contains "$output" "\"gos_version\":\"${gos_version}\"" "version json"

run_gos "$case_dir" bash "$script" current --json
[ "$status" -eq 0 ] || fail "current --json failed: ${output}"
assert_contains "$output" '"version":"1.20rc1"' "current json preserves rc"

run_gos "$case_dir" bash "$script" list --json
[ "$status" -eq 0 ] || fail "list --json failed: ${output}"
assert_contains "$output" '"versions":["go1.20.0","go1.21rc1","go1.21.6","go1.22rc1"]' "list json orders rc before its release"

run_gos "$case_dir" bash "$script" platforms 1.21.6 --json
[ "$status" -eq 0 ] || fail "platforms --json failed: ${output}"
assert_contains "$output" '"platforms":["darwin/arm64","linux/amd64"]' "platforms json"
pass "machine-readable current, list, version, and platforms work"

case_dir="${test_root}/pin"
mkdir -p "$case_dir/project"
(
  cd "$case_dir/project"
  run_gos "$case_dir" bash "$script" pin go1.21.6
  [ "$status" -eq 0 ] || fail "pin failed: ${output}"
  [ "$(<.go-version)" = "1.21.6" ] || fail "pin did not write normalized .go-version"
)
pass "pin writes normalized .go-version"

case_dir="${test_root}/use-go-version"
mkdir -p "$case_dir/project/sub"
printf 'go1.21.6\n' >"$case_dir/project/.go-version"
pushd "$case_dir/project/sub" >/dev/null
run_gos "$case_dir" bash "$script" use
popd >/dev/null
[ "$status" -eq 0 ] || fail "use .go-version failed: ${output}"
assert_contains "$output" "Using Go 1.21.6 from ${case_dir}/project/.go-version" "use .go-version"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "use did not install requested version"
pass "use installs version from nearest .go-version"

case_dir="${test_root}/use-go-mod"
mkdir -p "$case_dir/project"
cat >"$case_dir/project/go.mod" <<'GOMOD'
module example.com/test

go 1.20
toolchain go1.21.6
GOMOD
pushd "$case_dir/project" >/dev/null
run_gos "$case_dir" bash "$script" use
popd >/dev/null
[ "$status" -eq 0 ] || fail "use go.mod failed: ${output}"
assert_contains "$output" "Using Go 1.21.6 from ${case_dir}/project/go.mod" "use go.mod"
pass "use prefers go.mod toolchain over go directive"

case_dir="${test_root}/cache"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "initial cache install failed: ${output}"
rm -rf "${case_dir}/go"
GOS_TEST_DOWNLOAD_MODE="fail-archives" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "cached install failed: ${output}"
assert_contains "$output" "Using cached go1.21.6.darwin-arm64.tar.gz." "cache reuse"
pass "install reuses verified cached archives"

case_dir="${test_root}/rollback"
mkdir -p "$case_dir"
create_old_install "${case_dir}/go"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install before rollback failed: ${output}"
[ -d "${case_dir}/go.gos-rollback" ] || fail "rollback snapshot was not saved"
run_gos "$case_dir" bash "$script" rollback
[ "$status" -eq 0 ] || fail "rollback failed: ${output}"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "old" ] || fail "rollback did not restore previous install"
assert_contains "$output" "Rolled back! go version go1.20.0 darwin/arm64" "rollback output"
pass "rollback restores the previous Go installation"

case_dir="${test_root}/doctor"
run_gos "$case_dir" bash "$script" doctor --json
[ "$status" -eq 0 ] || fail "doctor --json failed: ${output}"
assert_contains "$output" '"status":"ok"' "doctor json"
assert_contains "$output" '"name":"checksum-hash"' "doctor json checks"
pass "doctor emits machine-readable diagnostics"

case_dir="${test_root}/unsupported"
GOS_TEST_UNSUPPORTED_PLATFORM=1 run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "unsupported platform should fail"
assert_contains "$output" "detected Plan9/mystery" "unsupported platform"
pass "unsupported platform errors include detected OS and arch"

case_dir="${test_root}/validate-version"
# The command-substitution payload is intentionally literal: it must reach
# gos.sh unexpanded to prove the validator rejects it.
# shellcheck disable=SC2016
for bad in '1.21.6;rm -rf /' '../1.21' '1.21.6$(touch pwned)' 'v1.21.6' '1'; do
  run_gos "$case_dir" bash "$script" install "$bad"
  [ "$status" -ne 0 ] || fail "install '${bad}' should fail"
  assert_contains "$output" "invalid version format" "version validation '${bad}'"
  if [ -s "${case_dir}/urls.log" ]; then
    fail "install '${bad}' must not reach the network"
  fi
done
run_gos "$case_dir" bash "$script" install ""
[ "$status" -ne 0 ] || fail "install with empty version should fail"
assert_contains "$output" "Usage: gos install <version>" "empty version usage"
pass "unsafe or malformed versions are rejected before any network access"

case_dir="${test_root}/validate-install-dir"
GOS_TEST_INSTALL_DIR="/usr" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "system-critical install dir should fail"
assert_contains "$output" "system-critical path" "install dir system path"
GOS_TEST_INSTALL_DIR="relative/go" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "relative install dir should fail"
assert_contains "$output" "must be an absolute path" "install dir relative path"
GOS_TEST_INSTALL_DIR="/golang" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "shallow install dir should fail"
assert_contains "$output" "too shallow" "install dir shallow path"
GOS_TEST_INSTALL_DIR="${case_dir}/payload" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "install dir without go basename should fail"
assert_contains "$output" "does not contain 'go'" "install dir basename"
GOS_TEST_INSTALL_DIR="/usr/local/../../etc/gogo" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "install dir with .. traversal should fail"
assert_contains "$output" "must not contain . or .. path components" "install dir dotdot"
GOS_TEST_INSTALL_DIR="/usr/local/./gogo" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "install dir with . component should fail"
assert_contains "$output" "must not contain . or .. path components" "install dir dot"
if [ -s "${case_dir}/urls.log" ]; then
  fail "install dir validation must run before any network access"
fi
pass "install dir guardrails refuse dangerous paths before any work"

case_dir="${test_root}/trailing-slash"
mkdir -p "$case_dir"
create_old_install "${case_dir}/go"
GOS_TEST_INSTALL_DIR="${case_dir}/go/" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "trailing-slash install failed: ${output}"
[ -d "${case_dir}/go.gos-rollback" ] || fail "trailing slash must not nest the rollback inside the install dir"
pass "trailing slashes in GOS_INSTALL_DIR are normalized"

case_dir="${test_root}/idempotent"
mkdir -p "$case_dir"
create_old_install "${case_dir}/go" "1.21.6" "served"
GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "idempotent install failed: ${output}"
assert_contains "$output" "Already on Go 1.21.6, nothing to do." "idempotent install"
if [ -s "${case_dir}/urls.log" ]; then
  fail "idempotent install must not reach the network"
fi
GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" latest
[ "$status" -eq 0 ] || fail "idempotent latest failed: ${output}"
assert_contains "$output" "Already on Go 1.21.6, nothing to do." "idempotent latest"
if grep -q 'dl/go1' "${case_dir}/urls.log"; then
  fail "idempotent latest must not download any archive"
fi
pass "installing the active version is a no-op when the install dir serves it"

case_dir="${test_root}/masked-install"
GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "masked install failed: ${output}"
assert_contains "$output" "does not provide it; installing" "masked install proceeds"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "masked install did not populate the install dir"
pass "a matching go elsewhere on PATH no longer masks a missing managed install"

case_dir="${test_root}/offline"
GOS_TEST_DOWNLOAD_MODE="fail-all" run_gos "$case_dir" bash "$script" latest
[ "$status" -ne 0 ] || fail "offline latest should fail"
assert_contains "$output" "could not fetch latest version" "offline latest"
GOS_TEST_DOWNLOAD_MODE="fail-all" run_gos "$case_dir" bash "$script" list
[ "$status" -ne 0 ] || fail "offline list should fail"
assert_contains "$output" "could not fetch the Go version list" "offline list"
GOS_TEST_DOWNLOAD_MODE="fail-all" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "offline install should fail"
assert_contains "$output" "download failed" "offline install"
GOS_TEST_DOWNLOAD_MODE="fail-all" run_gos "$case_dir" bash "$script" platforms 1.21.6
[ "$status" -ne 0 ] || fail "offline platforms should fail"
assert_contains "$output" "could not fetch the Go downloads feed" "offline platforms"
pass "network failures produce actionable errors and non-zero exits"

case_dir="${test_root}/prune"
mkdir -p "$case_dir"
create_old_install "${case_dir}/go"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "prune setup install failed: ${output}"
[ -f "${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz" ] || fail "prune setup did not cache archive"
[ -d "${case_dir}/go.gos-rollback" ] || fail "prune setup did not create rollback"
run_gos "$case_dir" bash "$script" prune
[ "$status" -eq 0 ] || fail "prune failed: ${output}"
assert_contains "$output" "Removed 1 cached Go archive(s)" "prune cache"
assert_contains "$output" "Rollback installation kept" "prune keeps rollback"
[ ! -f "${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz" ] || fail "prune left cached archive"
[ -d "${case_dir}/go.gos-rollback" ] || fail "prune must not remove rollback by default"
run_gos "$case_dir" bash "$script" prune --rollback
[ "$status" -eq 0 ] || fail "prune --rollback failed: ${output}"
assert_contains "$output" "Removed rollback installation" "prune rollback"
[ ! -d "${case_dir}/go.gos-rollback" ] || fail "prune --rollback left rollback dir"
run_gos "$case_dir" bash "$script" prune --bogus
[ "$status" -ne 0 ] || fail "prune with unknown option should fail"
assert_contains "$output" "unknown option for gos prune" "prune unknown option"
pass "prune clears cached archives and removes the rollback only on request"

case_dir="${test_root}/single-fetch"
run_gos "$case_dir" bash "$script" latest
[ "$status" -eq 0 ] || fail "latest install failed: ${output}"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "latest did not install newest version"
feed_fetches=$(grep -c 'mode=json' "${case_dir}/urls.log")
if [ "$feed_fetches" -ne 1 ]; then
  fail "latest should fetch the downloads feed exactly once, got ${feed_fetches}: $(cat "${case_dir}/urls.log")"
fi
pass "latest resolves version and checksum from a single feed request"

case_dir="${test_root}/use-no-manifest"
mkdir -p "${case_dir}/empty"
run_gos "$case_dir" bash "$script" use "${case_dir}/empty"
[ "$status" -ne 0 ] || fail "use without manifests should fail"
assert_contains "$output" "no .go-version or go.mod found" "use without manifests"
pass "use fails with a clear error when no project manifest exists"

case_dir="${test_root}/pin-no-arg"
run_gos "$case_dir" bash "$script" pin
[ "$status" -ne 0 ] || fail "pin without version should fail"
assert_contains "$output" "Usage: gos pin <version>" "pin without version"
pass "pin without a version prints usage and fails"

case_dir="${test_root}/check"
GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" check
[ "$status" -eq 0 ] || fail "check up-to-date failed: ${output}"
assert_contains "$output" "Already up to date." "check up to date"
GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check
[ "$status" -eq 0 ] || fail "check outdated failed: ${output}"
assert_contains "$output" "Update available. Install it with: gos latest" "check outdated"
if grep -q 'dl/go1' "${case_dir}/urls.log"; then
  fail "check must never download an archive"
fi
GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check --json
[ "$status" -eq 0 ] || fail "check --json failed: ${output}"
assert_contains "$output" '"current":"go1.20.0"' "check json current"
assert_contains "$output" '"latest":"go1.21.6"' "check json latest"
assert_contains "$output" '"up_to_date":false' "check json outdated"
GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" check --json
assert_contains "$output" '"up_to_date":true' "check json up to date"
pass "check reports update availability without installing"

case_dir="${test_root}/mirror"
GOS_TEST_MIRROR="https://mirror.test.invalid/dl" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "mirror install failed: ${output}"
assert_contains "$output" "Checksum verified." "mirror install verifies checksum"
grep -q '^https://mirror.test.invalid/dl/go1.21.6.darwin-arm64.tar.gz$' "${case_dir}/urls.log" \
  || fail "mirror install did not download the archive from the mirror"
grep -q 'https://go.dev/dl/?mode=json' "${case_dir}/urls.log" \
  || fail "mirror install must still resolve checksums from go.dev"
if grep -q '^https://go.dev/dl/go1' "${case_dir}/urls.log"; then
  fail "mirror install must not download archives from go.dev"
fi
pass "mirror installs download archives from the mirror with go.dev checksums"

case_dir="${test_root}/mirror-unverified"
GOS_TEST_MIRROR="https://mirror.test.invalid/dl" run_gos "$case_dir" bash "$script" install 1.19.0
[ "$status" -ne 0 ] || fail "mirror install without checksum metadata should fail"
assert_contains "$output" "no official checksum is available" "mirror requires checksum"
if grep -q 'mirror.test.invalid/dl/go1.19.0' "${case_dir}/urls.log"; then
  fail "mirror install without checksum must not download the archive"
fi
pass "mirror installs refuse to download unverifiable archives"

case_dir="${test_root}/mirror-invalid"
GOS_TEST_MIRROR="http://mirror.test.invalid/dl" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "plaintext mirror should fail"
assert_contains "$output" "must be an https:// URL" "mirror https enforcement"
pass "plaintext mirrors are rejected"

case_dir="${test_root}/self-update"
mkdir -p "${case_dir}/app"
cp "$script" "${case_dir}/app/gos"
chmod +x "${case_dir}/app/gos"
sed 's/^GOS_VERSION=.*/GOS_VERSION="9.9.9"/' "$script" >"${case_dir}/release-gos.sh"
GOS_TEST_SELFUPDATE_SCRIPT="${case_dir}/release-gos.sh" run_gos "$case_dir" bash "${case_dir}/app/gos" self-update
[ "$status" -eq 0 ] || fail "self-update failed: ${output}"
assert_contains "$output" "Checksum verified." "self-update checksum"
assert_contains "$output" "gos updated: v${gos_version} -> v9.9.9" "self-update version change"
grep -q '^GOS_VERSION="9.9.9"$' "${case_dir}/app/gos" || fail "self-update did not replace the script"
[ -x "${case_dir}/app/gos" ] || fail "self-update lost the executable bit"
GOS_TEST_SELFUPDATE_SCRIPT="${case_dir}/release-gos.sh" run_gos "$case_dir" bash "${case_dir}/app/gos" self-update
[ "$status" -eq 0 ] || fail "idempotent self-update failed: ${output}"
assert_contains "$output" "Already on the latest gos (v9.9.9)." "self-update idempotent"
pass "self-update replaces the script after checksum and syntax validation"

case_dir="${test_root}/resolve-minor"
run_gos "$case_dir" bash "$script" install 1.21
[ "$status" -eq 0 ] || fail "bare minor install failed: ${output}"
assert_contains "$output" "Resolved Go 1.21 to go1.21.6." "bare minor resolution"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "bare minor install did not install the newest patch"
pass "bare X.Y versions resolve to the newest patch release"

case_dir="${test_root}/broken-go"
GOS_TEST_GO_BROKEN=1 run_gos "$case_dir" bash "$script" current
[ "$status" -eq 0 ] || fail "current with broken go failed: ${output}"
assert_contains "$output" "No Go installation found." "current with broken go"
GOS_TEST_GO_BROKEN=1 run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install with broken go failed: ${output}"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "install with broken go did not install"
pass "a broken go binary on PATH does not abort gos"

case_dir="${test_root}/install-extra-arg"
run_gos "$case_dir" bash "$script" install 1.21.6 --json
[ "$status" -ne 0 ] || fail "install with trailing argument should fail"
assert_contains "$output" "unexpected argument for gos install" "install trailing argument"
pass "install rejects trailing arguments instead of ignoring them"

case_dir="${test_root}/corrupted-cache"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "corrupted-cache setup install failed: ${output}"
rm -rf "${case_dir}/go"
printf 'GOS-TEST-CORRUPT\n' >"${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install with corrupted cache failed: ${output}"
assert_contains "$output" "checksum mismatch; downloading a fresh archive." "corrupted cache warning"
assert_contains "$output" "Checksum verified." "corrupted cache re-download"
pass "corrupted cached archives are discarded and re-downloaded"

case_dir="${test_root}/prune-json"
mkdir -p "$case_dir"
create_old_install "${case_dir}/go"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "prune-json setup install failed: ${output}"
run_gos "$case_dir" bash "$script" prune --json
[ "$status" -eq 0 ] || fail "prune --json failed: ${output}"
assert_contains "$output" '"removed_archives":1' "prune json removed count"
assert_contains "$output" '"rollback":"kept"' "prune json rollback kept"
run_gos "$case_dir" bash "$script" prune --rollback --json
[ "$status" -eq 0 ] || fail "prune --rollback --json failed: ${output}"
assert_contains "$output" '"rollback":"removed"' "prune json rollback removed"
pass "prune supports machine-readable JSON output"

case_dir="${test_root}/rollback-missing"
run_gos "$case_dir" bash "$script" rollback
[ "$status" -ne 0 ] || fail "rollback without a snapshot should fail"
assert_contains "$output" "no rollback installation found" "rollback missing"
pass "rollback fails with a clear error when no snapshot exists"

case_dir="${test_root}/roll-forward"
mkdir -p "$case_dir"
create_old_install "${case_dir}/go"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "roll-forward setup install failed: ${output}"
run_gos "$case_dir" bash "$script" rollback
[ "$status" -eq 0 ] || fail "first rollback failed: ${output}"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "old" ] || fail "first rollback did not restore previous install"
run_gos "$case_dir" bash "$script" rollback
[ "$status" -eq 0 ] || fail "second rollback failed: ${output}"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "second rollback did not roll forward"
pass "rollback twice rolls forward to the displaced installation"

case_dir="${test_root}/env"
run_gos "$case_dir" bash "$script" env
[ "$status" -eq 0 ] || fail "env failed: ${output}"
assert_contains "$output" "export PATH=\"${case_dir}/go/bin:\$PATH\"" "env posix"
run_gos "$case_dir" bash "$script" env --fish
[ "$status" -eq 0 ] || fail "env --fish failed: ${output}"
assert_contains "$output" "fish_add_path --path '${case_dir}/go/bin'" "env fish"
run_gos "$case_dir" bash "$script" env --json
[ "$status" -eq 0 ] || fail "env --json failed: ${output}"
assert_contains "$output" "\"bin_dir\":\"${case_dir}/go/bin\"" "env json"
run_gos "$case_dir" bash "$script" env --bogus
[ "$status" -ne 0 ] || fail "env with unknown option should fail"
pass "env prints PATH setup for POSIX shells, fish, and JSON"

case_dir="${test_root}/versions-mode"
versions_dir="${case_dir}/versions"
GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "versions-mode install failed: ${output}"
[ -x "${versions_dir}/go1.21.6/bin/go" ] || fail "versions-mode did not install under GOS_VERSIONS_DIR"
[ -L "${case_dir}/go" ] || fail "versions-mode did not create an install-dir symlink"
[ "$(readlink "${case_dir}/go")" = "${versions_dir}/go1.21.6" ] || fail "install-dir symlink points at the wrong version"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "active symlink does not serve the new version"

GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" install 1.20.0
[ "$status" -eq 0 ] || fail "versions-mode second install failed: ${output}"
[ -x "${versions_dir}/go1.21.6/bin/go" ] || fail "previous version was removed by a new install"
[ "$(readlink "${case_dir}/go")" = "${versions_dir}/go1.20.0" ] || fail "symlink did not switch to the new version"

: >"${case_dir}/urls.log"
GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "versions-mode switch back failed: ${output}"
assert_contains "$output" "Using installed go1.21.6" "versions-mode fast path"
[ "$(readlink "${case_dir}/go")" = "${versions_dir}/go1.21.6" ] || fail "fast path did not repoint the symlink"
if grep -q 'dl/go1' "${case_dir}/urls.log"; then
  fail "switching to an installed version must not download anything"
fi

GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" list --installed
[ "$status" -eq 0 ] || fail "list --installed failed: ${output}"
assert_contains "$output" "go1.20.0" "list installed old"
assert_contains "$output" "go1.21.6" "list installed new"
GOS_TEST_VERSIONS_DIR="$versions_dir" GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" list --installed --json
[ "$status" -eq 0 ] || fail "list --installed --json failed: ${output}"
assert_contains "$output" '"installed":["go1.20.0","go1.21.6"]' "list installed json"
assert_contains "$output" '"active":"go1.21.6"' "list installed json active"

GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" uninstall 1.21.6
[ "$status" -ne 0 ] || fail "uninstalling the active version should fail"
assert_contains "$output" "is the active version" "uninstall active guard"
GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" uninstall 1.20.0
[ "$status" -eq 0 ] || fail "uninstall failed: ${output}"
[ ! -d "${versions_dir}/go1.20.0" ] || fail "uninstall left the version directory"
GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" uninstall 1.19.0
[ "$status" -ne 0 ] || fail "uninstalling a missing version should fail"
assert_contains "$output" "is not installed" "uninstall missing version"
pass "side-by-side mode installs, switches instantly, lists, and uninstalls versions"

case_dir="${test_root}/uninstall-flat"
run_gos "$case_dir" bash "$script" uninstall 1.21.6
[ "$status" -ne 0 ] || fail "uninstall in flat mode should fail"
assert_contains "$output" "requires side-by-side mode" "uninstall flat mode"
pass "uninstall explains it needs side-by-side mode"

case_dir="${test_root}/current-json-none"
GOS_TEST_GO_BROKEN=1 run_gos "$case_dir" bash "$script" current --json
[ "$status" -eq 0 ] || fail "current --json with broken go failed: ${output}"
assert_contains "$output" '{"found":false,"version":null,"current":null}' "current json none"
pass "current --json reports found:false when no working Go exists"

case_dir="${test_root}/cache-write-failure"
mkdir -p "$case_dir"
: >"${case_dir}/cache"   # a file where the cache dir should go: mkdir -p fails
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install with unwritable cache failed: ${output}"
assert_contains "$output" "could not write Go archive cache" "cache write warning"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "install with unwritable cache did not complete"
pass "an unwritable cache warns but never blocks an install"

case_dir="${test_root}/rollback-validation"
mkdir -p "$case_dir"
create_old_install "${case_dir}/go"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "rollback-validation setup install failed: ${output}"
cat >"${case_dir}/go.gos-rollback/bin/go" <<'BROKEN_GO'
#!/usr/bin/env bash
echo "go: exec format error" >&2
exit 1
BROKEN_GO
chmod +x "${case_dir}/go.gos-rollback/bin/go"
run_gos "$case_dir" bash "$script" rollback
[ "$status" -ne 0 ] || fail "rollback to a broken installation should fail"
assert_contains "$output" "rollback Go failed validation" "rollback validation error"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "failed rollback did not restore the current installation"
pass "a broken rollback snapshot fails validation and restores the current install"

case_dir="${test_root}/self-update-git"
mkdir -p "${case_dir}/repo/.git"
cp "$script" "${case_dir}/repo/gos"
GOS_TEST_SELFUPDATE_SCRIPT="${case_dir}/repo/gos" run_gos "$case_dir" bash "${case_dir}/repo/gos" self-update
[ "$status" -ne 0 ] || fail "self-update inside a git checkout should fail"
assert_contains "$output" "runs from a git checkout" "self-update git guard"
pass "self-update refuses to overwrite a git checkout"
