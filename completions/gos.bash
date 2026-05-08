#!/usr/bin/env bash
# Bash completion for gos

_gos_completions() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local commands="latest install use pin rollback current list platforms doctor version help"
  local options="--json"
  local words="$commands"

  if [ "$COMP_CWORD" -gt 1 ]; then
    words="$options"
  else
    words="$commands $options"
  fi

  COMPREPLY=()
  while IFS= read -r line; do
    COMPREPLY+=("$line")
  done < <(compgen -W "$words" -- "$cur")
}

complete -F _gos_completions gos
