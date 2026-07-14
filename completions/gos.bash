#!/usr/bin/env bash
# Bash completion for gos

_gos_completions() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local commands="latest install use pin check rollback uninstall prune current list platforms status which env completions doctor self-update version help"
  local cmd_index=1 cmd words="" line
  local versions=""

  # A leading --json shifts the command to the next position (gos --json list).
  if [ "${COMP_WORDS[1]:-}" = "--json" ]; then
    cmd_index=2
  fi

  COMPREPLY=()
  if [ "$COMP_CWORD" -le "$cmd_index" ]; then
    words="$commands"
    if [ "$cmd_index" -eq 1 ]; then
      words="$words --json"
    fi
  else
    cmd="${COMP_WORDS[$cmd_index]:-}"
    case "$cmd" in
      prune)
        words="--rollback --json"
        ;;
      install)
        if command -v gos >/dev/null 2>&1; then
          versions=$(gos __versions --remote-cached 2>/dev/null || true)
        fi
        words="$versions"
        ;;
      uninstall)
        if command -v gos >/dev/null 2>&1; then
          versions=$(gos __versions 2>/dev/null || true)
        fi
        words="$versions"
        ;;
      which)
        if command -v gos >/dev/null 2>&1; then
          versions=$(gos __versions 2>/dev/null || true)
        fi
        words="--json $versions"
        ;;
      list)
        words="--installed --json"
        ;;
      env)
        words="--fish --json"
        ;;
      completions)
        words="bash zsh fish"
        ;;
      doctor)
        words="--fix --json"
        ;;
      check|current|platforms|status|version)
        words="--json"
        ;;
      use)
        while IFS= read -r line; do
          COMPREPLY+=("$line")
        done < <(compgen -d -- "$cur")
        return
        ;;
      *)
        return
        ;;
    esac
  fi

  while IFS= read -r line; do
    COMPREPLY+=("$line")
  done < <(compgen -W "$words" -- "$cur")
}

complete -F _gos_completions gos
