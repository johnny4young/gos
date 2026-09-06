#!/usr/bin/env bash
set -euo pipefail
# gos-suite: skip-os=windows
# Property checks on version ordering: idempotent, order-independent, consistent
# with the pairwise comparator, and honoured by the per-minor filter.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
# shellcheck source=tests/lib-features.bash
. "${repo_root}/tests/lib-features.bash"

# A fixed seed keeps CI reproducible; GOS_TEST_SEED=<n> explores other inputs.
seed="${GOS_TEST_SEED:-20260904}"
sample="${test_root}/versions.txt"
awk -v seed="$seed" '
  BEGIN {
    srand(seed)
    for (i = 0; i < 120; i++) {
      v = "1." int(rand() * 30)
      r = rand()
      if (r < 0.6) v = v "." int(rand() * 16)
      r = rand()
      if (r < 0.15) v = v "rc" (1 + int(rand() * 4))
      else if (r < 0.25) v = v "beta" (1 + int(rand() * 3))
      print v
    }
  }
' >"$sample"

sort_versions() {
  PATH="${fake_bin}:${original_path}" bash -c 'set -euo pipefail; . "$1"; _gos_sort_versions' bash "$sourceable_script"
}

sorted="$(sort_versions <"$sample")"
[ "$(printf '%s\n' "$sorted" | wc -l | tr -d ' ')" = "$(wc -l <"$sample" | tr -d ' ')" ] || fail "sorting must keep every version"

resorted="$(printf '%s\n' "$sorted" | sort_versions)"
[ "$resorted" = "$sorted" ] || fail "sorting must be idempotent (seed ${seed})"

shuffled="$(awk -v seed="$((seed + 1))" 'BEGIN { srand(seed) } { print rand() "\t" $0 }' "$sample" | sort | cut -f2)"
[ "$(printf '%s\n' "$shuffled" | sort_versions)" = "$sorted" ] || fail "sorting must not depend on input order (seed ${seed})"
pass "version sorting is idempotent and order-independent"

# Every adjacent pair of the sorted list must agree with the pairwise
# comparator gos uses for check/latest: the earlier one is never newer.
pair_check="$(
  printf '%s\n' "$sorted" | PATH="${fake_bin}:${original_path}" bash -c '
    set -euo pipefail
    . "$1"
    previous=""
    while IFS= read -r version; do
      if [ -n "$previous" ] && _gos_go_version_is_newer "$previous" "$version"; then
        printf "%s > %s\n" "$previous" "$version"
      fi
      previous="$version"
    done
  ' bash "$sourceable_script"
)"
[ -z "$pair_check" ] || fail "sorted order disagrees with _gos_go_version_is_newer (seed ${seed}): ${pair_check}"
pass "sorted order agrees with the pairwise comparator"

# The newest-per-minor filter keeps exactly the last entry of each minor.
newest="$(printf '%s\n' "$sorted" | PATH="${fake_bin}:${original_path}" bash -c 'set -euo pipefail; . "$1"; _gos_newest_per_minor' bash "$sourceable_script")"
expected_newest="$(printf '%s\n' "$sorted" | awk '
  {
    v = $0
    match(v, /^[0-9]+\.[0-9]+/)
    key = substr(v, 1, RLENGTH)
    if (!(key in seen)) order[++n] = key
    seen[key] = 1
    last[key] = v
  }
  END { for (i = 1; i <= n; i++) print last[order[i]] }
')"
[ "$newest" = "$expected_newest" ] || fail "newest-per-minor must keep the last version of each minor in order (seed ${seed})"
pass "newest-per-minor keeps the last entry of every minor"
