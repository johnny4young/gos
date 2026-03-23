#compdef gos
# Zsh completion for gos

_gos() {
  local -a commands
  commands=(
    'latest:Install the latest stable Go version'
    'install:Install a specific Go version'
    'current:Show the currently active Go version'
    'list:List all available Go versions'
    'version:Show gos version'
    'help:Show help message'
  )

  _arguments '1:command:->cmds' '*::arg:->args'

  case "$state" in
    cmds)
      _describe -t commands 'gos command' commands
      ;;
  esac
}

_gos "$@"
