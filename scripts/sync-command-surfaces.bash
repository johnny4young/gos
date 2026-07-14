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

# Generate/check standalone command surfaces first, then embed completions into
# gos.sh. This keeps the public completions and the embedded fallback in the
# same state.
scripts/sync-bash-command-completions.bash "$mode"
scripts/sync-fish-command-completions.bash "$mode"
scripts/sync-zsh-command-completions.bash "$mode"
scripts/sync-readme-usage.bash "$mode"
scripts/sync-embedded-completions.bash "$mode"
