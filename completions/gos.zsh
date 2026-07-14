#compdef gos
# Zsh completion for gos

_gos() {
  local context state state_descr line
  typeset -A opt_args
  local -a commands
  commands=(
    'latest:Install the latest stable Go version'
    'install:Install a specific Go version'
    'use:Install the Go version requested by .go-version or go.mod'
    'pin:Write .go-version in the current directory'
    'check:Check whether a newer stable Go is available'
    'rollback:Restore the previous Go installation'
    'uninstall:Remove an installed version (side-by-side mode)'
    'prune:Remove cached Go archives and optionally the rollback copy'
    'current:Show the currently active Go version'
    'list:List available Go versions (or installed ones with --installed)'
    'platforms:List supported OS/arch archives for a Go version'
    'env:Print the PATH setup line for your shell'
    'completions:Print a Bash, Zsh, or Fish completion script'
    'doctor:Diagnose gos, Go, PATH, and tool dependencies'
    'self-update:Update gos itself to the latest release'
    'version:Show gos version'
    'help:Show help message'
  )

  _arguments '--json[Output machine-readable JSON where supported]' '1:command:->cmds' '*::arg:->args'

  case "$state" in
    cmds)
      _describe -t commands 'gos command' commands
      ;;
    args)
      case "${line[1]}" in
        prune)
          _arguments '--rollback[Also remove the rollback installation]' '--json[Output machine-readable JSON]'
          ;;
        list)
          _arguments '--installed[List locally installed versions]' '--json[Output machine-readable JSON]'
          ;;
        env)
          _arguments '--fish[Emit fish shell syntax]' '--json[Output machine-readable JSON]'
          ;;
        completions)
          _values 'shell' bash zsh fish
          ;;
        check|current|platforms|doctor|version)
          _arguments '--json[Output machine-readable JSON]'
          ;;
        use)
          _files -/
          ;;
      esac
      ;;
  esac
}

_gos "$@"
