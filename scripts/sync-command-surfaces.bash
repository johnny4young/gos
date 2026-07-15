#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s [--check|--write]\n' "${0##*/}" >&2
}

mode="${1:---check}"
if [ "$#" -gt 1 ]; then
  usage
  exit 2
fi
case "$mode" in
  --check | --write) ;;
  *)
    usage
    exit 2
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

transaction_dir=""
transaction_committed=0
transaction_targets=(
  README.md
  gos.sh
  completions/gos.bash
  completions/gos.fish
  completions/gos.zsh
)

finish_transaction() {
  transaction_committed=1
}

cleanup_transaction() {
  local exit_status="$1" file restore_failed=0

  trap - EXIT INT TERM
  if [ -n "$transaction_dir" ] && [ "$transaction_committed" -eq 0 ]; then
    for file in "${transaction_targets[@]}"; do
      if ! cp -p "${transaction_dir}/${file}" "$file"; then
        printf 'failed to restore command surface after sync failure: %s\n' "$file" >&2
        restore_failed=1
      fi
    done
    if [ "$restore_failed" -eq 0 ]; then
      printf 'rolled back command surface changes after sync failure\n' >&2
    fi
  fi

  if [ -n "$transaction_dir" ]; then
    rm -rf "$transaction_dir"
  fi
  if [ "$restore_failed" -ne 0 ]; then
    exit 1
  fi
  exit "$exit_status"
}

if [ "$mode" = "--write" ]; then
  transaction_dir="$(mktemp -d)"
  if ! mkdir -p "${transaction_dir}/completions"; then
    rm -rf "$transaction_dir"
    exit 1
  fi
  for file in "${transaction_targets[@]}"; do
    if ! cp -p "$file" "${transaction_dir}/${file}"; then
      rm -rf "$transaction_dir"
      exit 1
    fi
  done
  trap 'cleanup_transaction "$?"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
fi

# Generate/check standalone command surfaces first, then embed completions into
# gos.sh. This keeps the public completions and the embedded fallback in the
# same state.
scripts/sync-bash-command-completions.bash "$mode"
scripts/sync-fish-command-completions.bash "$mode"
scripts/sync-zsh-command-completions.bash "$mode"
scripts/sync-readme-usage.bash "$mode"
scripts/sync-embedded-completions.bash "$mode"

finish_transaction
