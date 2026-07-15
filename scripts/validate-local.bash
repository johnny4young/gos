#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: validate-local.bash [--help]

Run the local gos validation bundle.

Required checks:
  - generated command surfaces
  - Bash syntax for scripts/tests
  - repository Bash test suite
  - git whitespace checks

Optional tools are run when installed:
  - shellcheck
  - shfmt
  - zsh
  - fish
EOF
}

if [ "$#" -gt 1 ]; then
  usage >&2
  exit 2
fi

case "${1:-}" in
  "")
    ;;
  --help | -h)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

syntax_files=(
  gos.sh
  install.sh
  completions/gos.bash
  scripts/build-windows-package.bash
  scripts/sync-bash-command-completions.bash
  scripts/sync-command-surfaces.bash
  scripts/sync-embedded-completions.bash
  scripts/sync-fish-command-completions.bash
  scripts/sync-readme-usage.bash
  scripts/sync-zsh-command-completions.bash
  scripts/update-changelog.bash
  scripts/update-homebrew-tap.sh
  scripts/update-packaging.bash
  scripts/validate-local.bash
  tests/changelog.bash
  tests/checksum.bash
  tests/completions.bash
  tests/detection.bash
  tests/features.bash
  tests/homebrew-tap.bash
  tests/install-transaction.bash
  tests/install-sh.bash
  tests/install-ps1.bash
  tests/lib.bash
  tests/packaging.bash
  tests/windows-extract.bash
  tests/workflows.bash
)

test_scripts=(
  tests/changelog.bash
  tests/checksum.bash
  tests/completions.bash
  tests/detection.bash
  tests/features.bash
  tests/homebrew-tap.bash
  tests/install-transaction.bash
  tests/install-sh.bash
  tests/install-ps1.bash
  tests/packaging.bash
  tests/windows-extract.bash
  tests/workflows.bash
)

shellcheck_files=(
  gos.sh
  install.sh
  completions/gos.bash
  scripts/*.bash
  scripts/*.sh
  tests/*.bash
)

print_command() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
}

run() {
  print_command "$@"
  "$@"
}

run_optional() {
  local tool="$1"
  shift

  if command -v "$tool" >/dev/null 2>&1; then
    run "$tool" "$@"
  else
    printf '== skipped: %s is not installed ==\n' "$tool"
  fi
}

run scripts/sync-command-surfaces.bash --check
run_optional shfmt -d -i 2 -ci -bn .
run_optional shellcheck "${shellcheck_files[@]}"
run bash -n "${syntax_files[@]}"

for test_script in "${test_scripts[@]}"; do
  run bash "$test_script"
done

run_optional zsh -n completions/gos.zsh
run_optional fish --no-config --no-execute completions/gos.fish
run ./gos.sh version
run ./gos.sh help >/dev/null
run git diff --check

printf 'ok - local validation passed\n'
