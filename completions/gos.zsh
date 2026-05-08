#compdef gos
# Zsh completion for gos

_gos() {
  local -a commands
  commands=(
    'latest:Install the latest stable Go version'
    'install:Install a specific Go version'
    'use:Install the Go version requested by .go-version or go.mod'
    'pin:Write .go-version in the current directory'
    'rollback:Restore the previous Go installation'
    'current:Show the currently active Go version'
    'list:List all available Go versions'
    'platforms:List supported OS/arch archives for a Go version'
    'doctor:Diagnose gos, Go, PATH, and tool dependencies'
    'version:Show gos version'
    'help:Show help message'
  )

  _arguments '--json[Output machine-readable JSON where supported]' '1:command:->cmds' '*::arg:->args'

  case "$state" in
    cmds)
      _describe -t commands 'gos command' commands
      ;;
  esac
}

_gos "$@"
