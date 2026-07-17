#!/usr/bin/env bash
# Bash completion for gos

_gos_completions() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  # gos-commands:bash:begin
  local fallback_commands="latest install run use pin check rollback uninstall prune current list platforms status which env completions doctor self-update version help"
  # gos-commands:bash:end
  local commands="$fallback_commands"
  local cmd_index=1 cmd words="" line
  local versions=""

  if command -v gos >/dev/null 2>&1; then
    commands="$(gos __commands 2>/dev/null || printf '%s\n' "$fallback_commands")"
  fi

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
        words="--rollback --dry-run --json"
        ;;
      install | run)
        if command -v gos >/dev/null 2>&1; then
          versions=$(gos __versions --remote-cached 2>/dev/null || true)
        fi
        words="$versions"
        ;;
      uninstall)
        if command -v gos >/dev/null 2>&1; then
          versions=$(gos __versions 2>/dev/null || true)
        fi
        words="--inactive --dry-run $versions"
        ;;
      which)
        if command -v gos >/dev/null 2>&1; then
          versions=$(gos __versions 2>/dev/null || true)
        fi
        words="--json $versions"
        ;;
      list)
        words="--installed --minor --json"
        ;;
      rollback)
        words="--dry-run"
        ;;
      help)
        words="$commands"
        ;;
      env)
        words="--fish --auto --json"
        ;;
      completions)
        words="bash zsh fish"
        ;;
      doctor)
        words="--fix --json"
        ;;
      check | current | platforms | status | version)
        words="--json"
        ;;
      use)
        while IFS= read -r line; do
          COMPREPLY+=("$line")
        done < <(compgen -d -- "$cur")
        while IFS= read -r line; do
          COMPREPLY+=("$line")
        done < <(compgen -W "--print --json" -- "$cur")
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
