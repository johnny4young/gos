#!/usr/bin/env bash
# Bash completion for gos

_gos_completions() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local commands="latest install current list version help"

  COMPREPLY=()
  while IFS= read -r line; do
    COMPREPLY+=("$line")
  done < <(compgen -W "$commands" -- "$cur")
}

complete -F _gos_completions gos
