#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/gos.sh"
test_root="$(mktemp -d)"
real_tools_path="$PATH"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
  echo "not ok - $*" >&2
  exit 1
}

pass() {
  echo "ok - $*"
}

link_tool() {
  local tool="$1" target
  target=$(PATH="$real_tools_path" command -v "$tool") || fail "missing required tool: ${tool}"
  ln -sf "$target" "${case_bin}/${tool}"
}

write_go_tree_script() {
  local path="$1"
  cat >"$path" <<'FAKE_EXTRACTOR'
#!/usr/bin/env bash
set -euo pipefail

dest="$1"
mkdir -p "${dest}/go/bin"
cat >"${dest}/go/bin/go" <<'FAKE_GO_BIN'
#!/usr/bin/env bash
echo "go version go1.21.6 windows/amd64"
FAKE_GO_BIN
chmod +x "${dest}/go/bin/go"
printf 'new\n' >"${dest}/go/VERSION_MARKER"
FAKE_EXTRACTOR
  chmod +x "$path"
}

write_common_fakes() {
  cat >"${case_bin}/uname" <<'FAKE_UNAME'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  -s) echo "MINGW64_NT-10.0" ;;
  -m) echo "x86_64" ;;
  *) echo "MINGW64_NT-10.0" ;;
esac
FAKE_UNAME

  cat >"${case_bin}/curl" <<'FAKE_CURL'
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
    --proto)
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

case "$url" in
  'https://go.dev/dl/?mode=json'|'https://go.dev/dl/?mode=json&include=all')
    printf '[{"files":[{"filename":"go1.21.6.windows-amd64.zip","sha256":"expectedsha"}]}]\n'
    ;;
  https://go.dev/dl/go*)
    printf 'fake zip for %s\n' "$url" >"$output"
    ;;
  *)
    echo "unexpected curl URL: $url" >&2
    exit 1
    ;;
esac
FAKE_CURL

  cat >"${case_bin}/jq" <<'FAKE_JQ'
#!/usr/bin/env bash
set -euo pipefail

cat >/dev/null
printf 'expectedsha\n'
FAKE_JQ

  cat >"${case_bin}/sha256sum" <<'FAKE_SHA256SUM'
#!/usr/bin/env bash
set -euo pipefail

printf 'expectedsha  %s\n' "$1"
FAKE_SHA256SUM

  cat >"${case_bin}/go" <<'FAKE_GO'
#!/usr/bin/env bash
echo "go version go1.20.0 windows/amd64"
FAKE_GO

  write_go_tree_script "${case_bin}/write-go-tree"

  chmod +x "${case_bin}/uname" "${case_bin}/curl" "${case_bin}/jq" \
    "${case_bin}/sha256sum" "${case_bin}/go"

  for tool in bash dirname basename grep sed tr wc head mktemp rm chmod mv cut cat mkdir; do
    link_tool "$tool"
  done
}

write_unzip_fake() {
  cat >"${case_bin}/unzip" <<'FAKE_UNZIP'
#!/usr/bin/env bash
set -euo pipefail

dest=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d)
      dest="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

printf 'unzip\n' >>"$GOS_TEST_EXTRACT_LOG"
write-go-tree "$dest"
FAKE_UNZIP
  chmod +x "${case_bin}/unzip"
}

write_tar_fake() {
  cat >"${case_bin}/tar" <<'FAKE_TAR'
#!/usr/bin/env bash
set -euo pipefail

dest=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      dest="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

printf 'tar\n' >>"$GOS_TEST_EXTRACT_LOG"
write-go-tree "$dest"
FAKE_TAR
  chmod +x "${case_bin}/tar"
}

write_powershell_fakes() {
  cat >"${case_bin}/cygpath" <<'FAKE_CYGPATH'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" != "-w" ] || [ "$#" -ne 2 ]; then
  echo "unexpected cygpath args: $*" >&2
  exit 1
fi

printf 'cygpath %s\n' "$2" >>"$GOS_TEST_CYGPATH_LOG"
printf '%s\n' "$2"
FAKE_CYGPATH

  cat >"${case_bin}/powershell.exe" <<'FAKE_POWERSHELL'
#!/usr/bin/env bash
set -euo pipefail

: "${GOS_PS_ARCHIVE:?missing GOS_PS_ARCHIVE}"
: "${GOS_PS_DESTINATION:?missing GOS_PS_DESTINATION}"

{
  printf 'powershell\n'
  printf 'archive=%s\n' "$GOS_PS_ARCHIVE"
  printf 'destination=%s\n' "$GOS_PS_DESTINATION"
  printf 'args'
  printf ' <%s>' "$@"
  printf '\n'
} >>"$GOS_TEST_EXTRACT_LOG"

case " $* " in
  *"$GOS_PS_ARCHIVE"*|*"$GOS_PS_DESTINATION"*)
    echo "PowerShell command received interpolated path values" >&2
    exit 1
    ;;
esac

case " $* " in
  *"-LiteralPath"*'$env:GOS_PS_ARCHIVE'*"-DestinationPath"*'$env:GOS_PS_DESTINATION'*"-Force"*) ;;
  *)
    echo "PowerShell command did not use LiteralPath environment variables" >&2
    exit 1
    ;;
esac

write-go-tree "$GOS_PS_DESTINATION"
FAKE_POWERSHELL

  chmod +x "${case_bin}/cygpath" "${case_bin}/powershell.exe"
}

run_install() {
  local name="$1" extractor="$2"
  case_dir="${test_root}/${name} path with spaces 'quote"
  case_bin="${case_dir}/bin"
  install_dir="${case_dir}/go"
  extract_log="${case_dir}/extract.log"
  cygpath_log="${case_dir}/cygpath.log"
  output=""
  status=0

  mkdir -p "$case_bin"
  : >"$extract_log"
  : >"$cygpath_log"

  write_common_fakes

  case "$extractor" in
    unzip)
      write_unzip_fake
      write_tar_fake
      write_powershell_fakes
      ;;
    tar)
      write_tar_fake
      write_powershell_fakes
      ;;
    powershell)
      write_powershell_fakes
      ;;
    none)
      ;;
    *)
      fail "unknown extractor: ${extractor}"
      ;;
  esac

  set +e
  output="$(
    PATH="$case_bin" \
    GOS_INSTALL_DIR="$install_dir" \
    GOS_CACHE_DIR="${case_dir}/cache" \
    GOS_TEST_EXTRACT_LOG="$extract_log" \
    GOS_TEST_CYGPATH_LOG="$cygpath_log" \
    bash "$script" install 1.21.6 2>&1
  )"
  status=$?
  set -e
}

assert_status() {
  local expected="$1" actual="$2" name="$3"
  if [ "$actual" -ne "$expected" ]; then
    fail "${name}: expected status ${expected}, got ${actual}. Output: ${output}"
  fi
}

assert_nonzero_status() {
  local actual="$1" name="$2"
  if [ "$actual" -eq 0 ]; then
    fail "${name}: expected non-zero status. Output: ${output}"
  fi
}

assert_file_contains() {
  local file="$1" needle="$2" name="$3"
  if ! grep -Fq "$needle" "$file"; then
    fail "${name}: ${file} does not contain '${needle}'"
  fi
}

assert_file_not_contains() {
  local file="$1" needle="$2" name="$3"
  if grep -Fq "$needle" "$file"; then
    fail "${name}: ${file} unexpectedly contains '${needle}'"
  fi
}

assert_new_install_active() {
  local name="$1"
  if [ "$(cat "${install_dir}/VERSION_MARKER")" != "new" ]; then
    fail "${name}: new marker was not installed"
  fi
  if [ "$("${install_dir}/bin/go" version)" != "go version go1.21.6 windows/amd64" ]; then
    fail "${name}: new go binary is not active"
  fi
}

run_install "unzip_first" "unzip"
assert_status 0 "$status" "unzip first"
assert_file_contains "$extract_log" "unzip" "unzip first"
assert_file_not_contains "$extract_log" "tar" "unzip first"
assert_file_not_contains "$extract_log" "powershell" "unzip first"
assert_new_install_active "unzip first"
pass "Windows zip extraction prefers unzip"

run_install "tar_second" "tar"
assert_status 0 "$status" "tar second"
assert_file_contains "$extract_log" "tar" "tar second"
assert_file_not_contains "$extract_log" "powershell" "tar second"
assert_new_install_active "tar second"
pass "Windows zip extraction uses tar before PowerShell"

run_install "powershell_env" "powershell"
assert_status 0 "$status" "powershell env"
assert_file_contains "$extract_log" "powershell" "powershell env"
assert_file_contains "$extract_log" 'args <-NoProfile> <-NonInteractive> <-Command>' "powershell env"
assert_file_contains "$extract_log" "\$env:GOS_PS_ARCHIVE" "powershell env"
assert_file_contains "$extract_log" "\$env:GOS_PS_DESTINATION" "powershell env"
assert_file_contains "$cygpath_log" "cygpath" "powershell env"
assert_new_install_active "powershell env"
pass "Windows PowerShell fallback uses LiteralPath environment variables"

run_install "no_tools" "none"
assert_nonzero_status "$status" "no tools"
case "$output" in
  *"no extraction tool found"*) ;;
  *) fail "no tools: missing extraction error. Output: ${output}" ;;
esac
pass "Windows zip extraction fails clearly without tools"
