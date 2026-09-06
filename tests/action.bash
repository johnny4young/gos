#!/usr/bin/env bash
set -euo pipefail
# Run the actual composite run blocks offline with controlled runner inputs.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
ruby -ryaml -e 'YAML.load_file(ARGV[0]).fetch("runs").fetch("steps").each { |s| File.write(File.join(ARGV[1], s["id"] + ".bash"), s["run"]) if s["run"] && s["id"] }' "$repo_root/action.yml" "$test_root"
mkdir -p "$test_root/action/packaging/windows" "$test_root/bin" "$test_root/home" "$test_root/project"
cp "$repo_root/packaging/windows/gos.cmd" "$test_root/action/packaging/windows/gos.cmd"
cat >"$test_root/action/gos.sh" <<'GOS'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  use) printf 'go1.25\n' ;;
  list) printf '{"versions":["go1.24.9","go1.25.7","go1.26.2"]}\n' ;;
  install)
    case "$GOS_INSTALL_DIR" in /*) ;; *) exit 23 ;; esac
    [ "$GOS_CACHE_DIR" = "$HOME/.cache/gos" ] || exit 24
    [ -z "$GOS_VERSIONS_DIR" ] || exit 25
    mkdir -p "$GOS_INSTALL_DIR/bin"
    printf '#!/usr/bin/env bash\nprintf "go version go%s test/amd64\\n"\n' "$2" >"$GOS_INSTALL_DIR/bin/go"
    chmod +x "$GOS_INSTALL_DIR/bin/go"
    ;;
esac
GOS
cat >"$test_root/bin/cygpath" <<'CYG'
#!/usr/bin/env bash
case "$1" in
  -u) printf '%s\n' "$GOS_TEST_WINDOWS_ROOT" ;;
  -w) printf 'D:\\native\\go\n' ;;
  *) exit 1 ;;
esac
CYG
chmod +x "$test_root/bin/cygpath"
export GITHUB_ACTION_PATH="$test_root/action" GITHUB_OUTPUT="$test_root/output"
export GITHUB_ENV="$test_root/env" GITHUB_PATH="$test_root/path" HOME="$test_root/home"
export INPUT_PROJECT_DIR="$test_root/project" INPUT_INSTALL_DIR="" RUNNER_OS=Linux RUNNER_ARCH=X64
resolve() {
  : >"$GITHUB_OUTPUT"
  status=0
  bash "$test_root/resolve.bash" >"$test_root/log" 2>&1 || status=$?
}
for request in '' 1.25 go1.25.7 latest 1.27rc1; do
  export INPUT_GO_VERSION="$request"
  resolve
  assert_status 0 "$status" "action resolves $request" "$(cat "$test_root/log")"
  case "$request" in latest) expected=1.26.2 ;; 1.27rc1) expected=1.27rc1 ;; *) expected=1.25.7 ;; esac
  grep -Fxq "version=$expected" "$GITHUB_OUTPUT" || fail "action resolved wrong exact version"
done
for invalid in '1.*' '--help' $'1.25.7\ncache-key=injected'; do
  export INPUT_GO_VERSION="$invalid"
  resolve
  [ "$status" -ne 0 ] || fail "action accepted invalid version input"
  [ ! -s "$GITHUB_OUTPUT" ] || fail "invalid version reached runner outputs"
done
export INPUT_GO_VERSION=1.25.7 INPUT_INSTALL_DIR=$'/tmp/go\nversion=1.0.0'
resolve
[ "$status" -ne 0 ] && [ ! -s "$GITHUB_OUTPUT" ] || fail "multiline path reached runner outputs"
pass "action resolves project/minor/latest/exact versions and rejects unsafe runner-output inputs"

export RUNNER_OS=Windows INPUT_INSTALL_DIR='D:\custom path\go'
export GOS_TEST_WINDOWS_ROOT="$test_root/windows go"
export PATH="$test_root/bin:$PATH"
resolve
assert_status 0 "$status" "Windows action resolve" "$(cat "$test_root/log")"
export GOS_INSTALL_DIR
GOS_INSTALL_DIR=$(sed -n 's/^install-dir=//p' "$GITHUB_OUTPUT")
[ "$GOS_INSTALL_DIR" = "$GOS_TEST_WINDOWS_ROOT" ] || fail "native Windows install-dir was not normalized"
export GOS_VERSION_TO_INSTALL=1.25.7 GOS_REQUIRE_CHECKSUM=feed GOS_CACHE_DIR=/wrong/cache GOS_VERSIONS_DIR=/wrong/versions
: >"$GITHUB_OUTPUT"
bash "$test_root/install.bash" >"$test_root/log" 2>&1 || fail "Windows action install: $(cat "$test_root/log")"
for launcher in gos gos.sh gos.cmd; do
  [ -f "$HOME/.gos/bin/$launcher" ] || fail "action omitted Windows launcher $launcher"
done
grep -Fxq 'GOROOT=D:\native\go' "$GITHUB_ENV" || fail "action did not export native GOROOT"
grep -Fxq "GOS_INSTALL_DIR=$GOS_INSTALL_DIR" "$GITHUB_ENV" || fail "action did not preserve Bash install root"
grep -Fxq "GOS_CACHE_DIR=$HOME/.cache/gos" "$GITHUB_ENV" || fail "action cache disagrees with actions/cache path"
pass "action normalizes Windows paths, installs Bash and native launchers, and exports matching roots"
