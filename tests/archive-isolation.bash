#!/usr/bin/env bash
set -euo pipefail
# gos-suite: skip-os=windows
# Real archives and digests exercise the bytes installed, not just fake output.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
# shellcheck source=tests/lib-features.bash
. "${repo_root}/tests/lib-features.bash"

real_tar=$(command -v tar)
real_shasum=$(command -v shasum)
pkg=go1.21.6.darwin-arm64.tar.gz
make_archive() {
  local archive="$1" marker="$2"
  mkdir -p "${test_root}/payload/go/bin"
  printf '#!/usr/bin/env bash\nprintf "go version go1.21.6 darwin/arm64\\n"\n' >"${test_root}/payload/go/bin/go"
  chmod +x "${test_root}/payload/go/bin/go"
  printf '%s\n' "$marker" >"${test_root}/payload/go/VERSION_MARKER"
  "$real_tar" -czf "$archive" -C "${test_root}/payload" go
}
make_archive "${test_root}/approved.tar.gz" approved
make_archive "${test_root}/replacement.tar.gz" replacement
digest=$("$real_shasum" -a 256 "${test_root}/approved.tar.gz" | cut -d' ' -f1)
rm "${fake_bin}/tar"
ln -s "$real_tar" "${fake_bin}/tar"
mv "${fake_bin}/curl" "${test_root}/original-curl"
cat >"${fake_bin}/curl" <<CURL
#!/usr/bin/env bash
set -euo pipefail
output=""
url=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) output="\$2"; shift 2 ;;
    *) url="\$1"; shift ;;
  esac
done
case "\$url" in
  *.tar.gz) "$real_cp" "${test_root}/approved.tar.gz" "\$output" ;;
  *) "${test_root}/original-curl" "\$url" | sed 's/expectedsha/$digest/g' ;;
esac
CURL
cat >"${fake_bin}/sha256sum" <<HASH
#!/usr/bin/env bash
set -euo pipefail
result=\$("$real_shasum" -a 256 "\$1")
if [ -n "\${GOS_TEST_SWAP_FILE:-}" ]; then
  "$real_cp" "${test_root}/replacement.tar.gz" "\$GOS_TEST_SWAP_FILE"
fi
printf '%s\\n' "\$result"
HASH
chmod +x "${fake_bin}/curl" "${fake_bin}/sha256sum"

for source in cache partial; do
  case_dir="${test_root}/replace-${source}"
  mkdir -p "${case_dir}/cache"
  swap="${case_dir}/cache/${pkg}.partial"
  if [ "$source" = cache ]; then
    swap="${case_dir}/cache/${pkg}"
    cp "${test_root}/approved.tar.gz" "$swap"
  fi
  GOS_TEST_SWAP_FILE="$swap" run_gos "$case_dir" bash "$script" install 1.21.6
  assert_status 0 "$status" "${source} replaced after hashing" "$output"
  [ "$(cat "${case_dir}/go/VERSION_MARKER")" = approved ] || fail "${source} replacement changed the installed bytes after checksum verification"
  if [ "$source" = partial ]; then
    [ "$("$real_shasum" -a 256 "${case_dir}/cache/${pkg}" | cut -d' ' -f1)" = "$digest" ] || fail "partial replacement changed the published cache bytes"
  fi
done
pass "cache and completed-download replacements cannot change verified installation bytes"

case_dir="${test_root}/cache-symlink"
mkdir -p "${case_dir}/cache"
printf preserved >"${case_dir}/unrelated"
ln -s "${case_dir}/unrelated" "${case_dir}/cache/${pkg}"
run_gos "$case_dir" bash "$script" install 1.21.6 --from-file "${test_root}/approved.tar.gz" --sha256 "$digest"
assert_status 0 "$status" "publish over a cache symlink" "$output"
[ "$(cat "${case_dir}/unrelated")" = preserved ] || fail "cache publication overwrote the symlink target"
[ ! -L "${case_dir}/cache/${pkg}" ] || fail "cache publication must replace the symlink itself"
pass "cache publication preserves an unrelated symlink target"

case_dir="${test_root}/cache-directory"
mkdir -p "${case_dir}/cache/${pkg}"
run_gos "$case_dir" bash "$script" install 1.21.6 --from-file "${test_root}/approved.tar.gz" --sha256 "$digest"
assert_status 0 "$status" "directory occupies cache entry" "$output"
assert_contains "$output" 'could not write Go archive cache' "cache directory warning"
[ -z "$(ls -A "${case_dir}/cache/${pkg}")" ] || fail "cache publication wrote inside the existing directory"
pass "an existing directory cannot redirect cache publication"

for kind in symlink directory; do
  case_dir="${test_root}/partial-${kind}"
  mkdir -p "${case_dir}/cache"
  partial="${case_dir}/cache/${pkg}.partial"
  if [ "$kind" = symlink ]; then
    printf preserved >"${case_dir}/unrelated"
    ln -s "${case_dir}/unrelated" "$partial"
  else
    mkdir "$partial"
  fi
  run_gos "$case_dir" bash "$script" install 1.21.6
  assert_status 0 "$status" "${kind} occupies partial path" "$output"
  if [ "$kind" = symlink ]; then
    [ "$(cat "${case_dir}/unrelated")" = preserved ] || fail "download overwrote a partial symlink target"
    [ -L "$partial" ] || fail "download removed a partial symlink it did not own"
  else
    [ -d "$partial" ] && [ -z "$(ls -A "$partial")" ] || fail "download modified the existing partial directory"
  fi
done
pass "non-regular partial paths are bypassed without mutation"

# Publication goes through mktemp (0600); entries must keep the umask mode so
# a cache shared between accounts stays readable.
case_dir="${test_root}/cache-mode"
(umask 022 && run_gos "$case_dir" bash "$script" install 1.21.6 --from-file "${test_root}/approved.tar.gz" --sha256 "$digest" \
  && [ "$status" -eq 0 ]) || fail "install for cache mode check failed"
# GNU stat uses -c, BSD/macOS stat uses -f.
mode=$(stat -c '%a' "${case_dir}/cache/${pkg}" 2>/dev/null || stat -f '%Lp' "${case_dir}/cache/${pkg}")
[ "$mode" = 644 ] || fail "cache publication must follow the umask, got mode ${mode}"
pass "published cache entries follow the umask instead of mktemp's 0600"

# An unreadable cache entry is a cache miss, not raw cp noise on stderr.
if [ "$(id -u)" != 0 ]; then
  case_dir="${test_root}/cache-unreadable"
  mkdir -p "${case_dir}/cache"
  cp "${test_root}/approved.tar.gz" "${case_dir}/cache/${pkg}"
  chmod 000 "${case_dir}/cache/${pkg}"
  run_gos "$case_dir" bash "$script" install 1.21.6
  chmod 644 "${case_dir}/cache/${pkg}"
  assert_status 0 "$status" "unreadable cache entry" "$output"
  assert_contains "$output" "could not be read; downloading a fresh archive" "unreadable cache warning"
  assert_not_contains "$output" "cp:" "unreadable cache cp noise"
  pass "an unreadable cache entry falls back to a download without cp noise"
fi

# A failed staging copy must leave an existing cache entry intact, and remove
# its incomplete private publication file. No download or mock digest involved.
case_dir="${test_root}/publication-failure"
mkdir -p "${case_dir}/cache"
printf preserved >"${case_dir}/cache/${pkg}"
cat >"${fake_bin}/cp" <<COPY
#!/usr/bin/env bash
set -euo pipefail
for destination in "\$@"; do :; done
case "\$destination" in
  "${case_dir}/cache/"*)
    printf truncated >"\$destination"
    exit 1
    ;;
esac
exec "$real_cp" "\$@"
COPY
run_gos "$case_dir" bash "$script" install 1.21.6 --from-file "${test_root}/approved.tar.gz" --sha256 "$digest"
assert_status 0 "$status" "cache staging copy failure" "$output"
assert_contains "$output" 'could not write Go archive cache' "cache staging failure warning"
[ "$(cat "${case_dir}/cache/${pkg}")" = preserved ] || fail "failed publication damaged the previous cache entry"
[ "$(cat "${case_dir}/go/VERSION_MARKER")" = approved ] || fail "cache staging failure prevented a verified install"
for leftover in "${case_dir}/cache/"*.partial*; do
  [ ! -e "$leftover" ] || fail "failed publication leaked ${leftover}"
done
pass "failed cache publication preserves the old entry, cleans staging, and completes the install"

# Untrappable termination can leave a publication temporary. The cache's
# existing prune contract must reclaim it as well as ordinary resumable files.
case_dir="${test_root}/publication-residue"
mkdir -p "${case_dir}/cache"
printf residue >"${case_dir}/cache/${pkg}.partial.abcdef"
printf resume >"${case_dir}/cache/${pkg}.partial"
printf keep >"${case_dir}/cache/unrelated"
run_gos "$case_dir" bash "$script" prune --json
assert_status 0 "$status" "prune publication residue" "$output"
assert_contains "$output" '"removed_archives":2' "prune counts publication and resumable files"
[ "$(ls -A "${case_dir}/cache")" = unrelated ] || fail "prune must remove publication residue and preserve unrelated files"
pass "prune reclaims abandoned publication files and preserves unrelated files"
