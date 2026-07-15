#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: validate-local.bash [--required-only|--help]

Run the local gos validation bundle.

Required checks:
  - generated command surfaces
  - workflow YAML syntax
  - Bash syntax for scripts/tests
  - repository Bash test suite
  - CLI smoke checks
  - git whitespace checks

Required external tools:
  - ruby (workflow YAML syntax)

Options:
  --required-only  skip optional tools and run only required checks
  --help, -h       show this help

Optional tools are run when installed unless --required-only is set:
  - shellcheck
  - shfmt
  - zsh
  - fish
  - pwsh or powershell
EOF
}

run_optional_checks=1

if [ "$#" -gt 1 ]; then
  usage >&2
  exit 2
fi

case "${1:-}" in
  "")
    ;;
  --required-only)
    run_optional_checks=0
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

powershell_files=(
  install.ps1
  packaging/windows/uninstall.ps1
  tests/install-ps1.ps1
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

run_quiet() {
  print_command "$@"
  "$@" >/dev/null
}

require_tool() {
  local tool="$1"
  local description="$2"

  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'missing required tool: %s (%s)\n' "$tool" "$description" >&2
    return 127
  fi
}

run_optional() {
  local tool="$1"
  shift

  if [ "$run_optional_checks" -eq 0 ]; then
    printf '== skipped: %s optional checks disabled ==\n' "$tool"
    return 0
  fi

  if command -v "$tool" >/dev/null 2>&1; then
    run "$tool" "$@"
  else
    printf '== skipped: %s is not installed ==\n' "$tool"
  fi
}
run_optional_powershell() {
  local powershell_bin=""
  local powershell_file
  local powershell_parse_script
  local -a powershell_args=()

  if [ "$run_optional_checks" -eq 0 ]; then
    printf '== skipped: pwsh/powershell optional checks disabled ==\n'
    return 0
  fi

  if command -v pwsh >/dev/null 2>&1; then
    powershell_bin="pwsh"
    powershell_args=("$powershell_bin" -NoProfile)
  elif command -v powershell >/dev/null 2>&1; then
    powershell_bin="powershell"
    powershell_args=("$powershell_bin" -NoProfile -ExecutionPolicy Bypass)
  else
    printf '== skipped: pwsh/powershell is not installed ==\n'
    return 0
  fi

  for powershell_file in "${powershell_files[@]}"; do
    [ -f "$powershell_file" ] || {
      printf 'missing PowerShell validation file: %s\n' "$powershell_file" >&2
      return 1
    }
  done

  # PowerShell variables must remain literal until the PowerShell process runs.
  # shellcheck disable=SC2016
  powershell_parse_script='
$ErrorActionPreference = "Stop"
$files = @("install.ps1", "packaging/windows/uninstall.ps1", "tests/install-ps1.ps1")
foreach ($file in $files) {
  $errors = $null
  $tokens = $null
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file), [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors.Count) {
    $errors | Format-List
    exit 1
  }
}
'

  run "${powershell_args[@]}" -Command "$powershell_parse_script"
  run "${powershell_args[@]}" -File tests/install-ps1.ps1
}

require_tool ruby "workflow YAML syntax validation"

run scripts/sync-command-surfaces.bash --check
run_optional shfmt -d -i 2 -ci -bn .
run_optional shellcheck "${shellcheck_files[@]}"
run bash -n "${syntax_files[@]}"

for test_script in "${test_scripts[@]}"; do
  run bash "$test_script"
done

run_optional zsh -n completions/gos.zsh
run_optional fish --no-config --no-execute completions/gos.fish
run_optional_powershell
run ./gos.sh version
run_quiet ./gos.sh help
run ruby -e 'require "yaml"; YAML.load_file(".github/workflows/ci.yml"); YAML.load_file(".github/workflows/release.yml"); YAML.load_file(".github/workflows/canary.yml")'
run git diff --check

printf 'ok - local validation passed\n'
