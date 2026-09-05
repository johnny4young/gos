#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: validate-local.bash [--required-only|--strict|--help]

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
  --strict         fail when an optional tool is missing (CI parity)
  --help, -h       show this help

Test suites run in parallel (scripts/run-tests.bash); set GOS_TEST_JOBS=1
for serial output.

Optional tools are run when installed unless --required-only is set:
  - shellcheck
  - shfmt
  - zsh
  - fish
  - pwsh or powershell
EOF
}

run_optional_checks=1
strict_optional_tools=0

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
  --strict)
    strict_optional_tools=1
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

# Every tracked shell file, from git like CI's syntax gate, so a new script
# or suite needs no registration here either.
syntax_files=()
while IFS= read -r tracked_shell_file; do
  syntax_files=(${syntax_files[@]:+"${syntax_files[@]}"} "$tracked_shell_file")
done <<EOF
$(git ls-files '*.sh' '*.bash')
EOF

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
  packaging/chocolatey/tools/chocolateyInstall.ps1
  packaging/chocolatey/tools/chocolateyUninstall.ps1
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
  elif [ "$strict_optional_tools" -eq 1 ]; then
    printf 'missing optional tool required by --strict: %s (CI runs it)\n' "$tool" >&2
    exit 127
  else
    printf '== skipped: %s is not installed (CI runs it) ==\n' "$tool"
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
    if [ "$strict_optional_tools" -eq 1 ]; then
      printf 'missing optional tool required by --strict: pwsh or powershell (CI runs it)\n' >&2
      exit 127
    fi
    printf '== skipped: pwsh/powershell is not installed (CI runs it) ==\n'
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
foreach ($file in $args) {
  $errors = $null
  $tokens = $null
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file), [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors.Count) {
    $errors | Format-List
    exit 1
  }
}
'

  run "${powershell_args[@]}" -Command "$powershell_parse_script" "${powershell_files[@]}"
  run "${powershell_args[@]}" -File tests/install-ps1.ps1
}

require_tool ruby "workflow YAML syntax validation"

run scripts/sync-command-surfaces.bash --check
run_optional shfmt -d -i 2 -ci -bn .
run_optional shellcheck "${shellcheck_files[@]}"
run bash -n "${syntax_files[@]}"

# Every tracked tests/*.bash suite, discovered by the runner (see its header
# for the per-OS rules); GOS_TEST_JOBS=1 runs them serially.
run scripts/run-tests.bash --jobs "${GOS_TEST_JOBS:-auto}"

run_optional zsh -n completions/gos.zsh
run_optional fish --no-config --no-execute completions/gos.fish
run_optional_powershell
run ./gos.sh version
run_quiet ./gos.sh help
run ruby -e 'require "yaml"; workflows = Dir[".github/workflows/*.{yml,yaml}"].sort; abort "no GitHub Actions workflows found" if workflows.empty?; workflows.each { |path| YAML.load_file(path) }'
run git diff --check

printf 'ok - local validation passed\n'
