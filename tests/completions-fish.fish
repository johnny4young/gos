# Real Fish completion queries, with no network or user shell configuration.
source $argv[1]
cd $argv[2]
function gos
  echo 1.21.6
end
function gos-probe-command
end
complete -c gos-probe-command -l probe-flag

touch fixture-target
function expect_candidate --argument-names line expected
  set -l candidates (complete -C "$line" | string split -f 1 \t)
  if not contains -- "$expected" $candidates
    printf 'not ok - Fish %s: missing %s in %s\n' "$line" "$expected" "$candidates" >&2
    exit 1
  end
end
expect_candidate 'gos run ' --
expect_candidate 'gos run ' 1.21.6
expect_candidate 'gos each ' 1.21.6
if contains -- -- (complete -C 'gos each ' | string split -f 1 \t)
  echo 'not ok - Fish each must not offer bare --' >&2
  exit 1
end
expect_candidate 'gos --json ' status
expect_candidate 'gos pin ' 1.21.6
expect_candidate 'gos platforms ' 1.21.6
for prefix in 'gos run --' 'gos run 1.21.6' 'gos run 1.21.6 --' 'gos each 1.21.6' 'gos each 1.21.6 --'
  expect_candidate "$prefix gos-probe-" gos-probe-command
  expect_candidate "$prefix gos-probe-command --probe-" --probe-flag
  expect_candidate "$prefix gos-probe-command fixture-t" fixture-target
end
# Nested gos command names must not activate the outer command's flags.
if contains -- --json (complete -C 'gos run -- gos-probe-command check --' | string split -f 1 \t)
  echo 'not ok - Fish leaked gos check flags into nested arguments' >&2
  exit 1
end
echo 'ok - real Fish completion preserves project/explicit versions and nested argv'
