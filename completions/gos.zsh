#compdef gos
# Zsh completion for gos

_gos() {
  local context state state_descr line
  typeset -A opt_args
  local -a commands
  # gos-commands:zsh:begin
  commands=(
    'latest:Install the latest stable Go version'
    'install:Install a specific Go version'
    'run:Run a command with a side-by-side Go version without activating it globally'
    'use:Install the Go version requested by .go-version, .tool-versions, or go.mod'
    'pin:Write .go-version in the current directory (active version by default)'
    'check:Check whether newer stable Go or gos releases are available (no install)'
    'rollback:Restore the previous Go installation, if available'
    'uninstall:Remove an installed version (side-by-side mode)'
    'prune:Remove cached Go archives; --rollback also removes the rollback copy'
    'current:Show the currently active Go version'
    'list:List available Go versions (or locally installed ones); --minor keeps the newest per minor'
    'platforms:List supported OS/arch archives for a Go version'
    'status:Show an offline dashboard for gos and the active Go'
    'which:Show the active or side-by-side Go binary path'
    'env:Print the PATH setup line or an opt-in per-shell auto-switch hook'
    'completions:Print a Bash, Zsh, or Fish completion script'
    'doctor:Diagnose gos, Go, PATH, and local tool dependencies; --fix creates safe missing directories and prints the shell setup line'
    'self-update:Update gos itself to the latest verified release'
    'version:Show gos version'
    'help:Show this help message'
  )
  # gos-commands:zsh:end

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
        install | run)
          if command -v gos >/dev/null 2>&1; then
            _values 'Go version' ${(f)"$(gos __versions --remote-cached 2>/dev/null)"}
          fi
          ;;
        uninstall)
          if command -v gos >/dev/null 2>&1; then
            _values 'Installed Go version' ${(f)"$(gos __versions 2>/dev/null)"}
          fi
          ;;
        which)
          _arguments '--json[Output machine-readable JSON]'
          if command -v gos >/dev/null 2>&1; then
            _values 'Installed Go version' ${(f)"$(gos __versions 2>/dev/null)"}
          fi
          ;;
        list)
          _arguments '--installed[List locally installed versions]' '--minor[Keep only the newest version per minor]' '--json[Output machine-readable JSON]'
          ;;
        env)
          _arguments '--fish[Emit fish shell syntax]' '--auto[Emit opt-in auto-switch hook]' '--json[Output machine-readable JSON]'
          ;;
        completions)
          _values 'shell' bash zsh fish
          ;;
        doctor)
          _arguments '--fix[Apply safe non-destructive fixes]' '--json[Output machine-readable JSON]'
          ;;
        check | current | platforms | status | version)
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
