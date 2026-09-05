# Fish completion for gos

complete -c gos -f

# True while no command has been typed yet. Unlike __fish_use_subcommand it
# ignores a leading --json, so `gos --json <TAB>` still offers the commands.
function __gos_needs_command
  set -l tokens (commandline -opc)
  set -e tokens[1]
  for token in $tokens
    test "$token" = --json; or return 1
  end
  return 0
end

# True while run/each still expect their version slot (nothing typed after
# the command yet); afterwards the rest of the line is the command to run.
function __gos_wants_version
  set -l tokens (commandline -opc)
  set -e tokens[1]
  if test "$tokens[1]" = --json
    set -e tokens[1]
  end
  test (count $tokens) -eq 1
end

# Match the actual gos command, never a word inside run/each's nested argv.
function __gos_using_command
  set -l tokens (commandline -opc)
  set -e tokens[1]
  if test "$tokens[1]" = --json
    set -e tokens[1]
  end
  contains -- "$tokens[1]" $argv
end

function __gos_complete_command
  set -l tokens (commandline -opc)
  set -e tokens[1]
  if test "$tokens[1]" = --json
    set -e tokens[1]
  end
  # Fish skips non-option tokens, so bare -- does not occupy the version slot.
  if test "$tokens[1]" = run; and test "$tokens[2]" = --
    __fish_complete_subcommand --fcs-skip=2
  else
    __fish_complete_subcommand --fcs-skip=3
  end
end

# gos-commands:fish:begin
complete -c gos -n '__gos_needs_command' -a 'latest' -d 'Install the latest stable Go version'
complete -c gos -n '__gos_needs_command' -a 'install' -d 'Install a specific Go version'
complete -c gos -n '__gos_needs_command' -a 'rollback' -d 'Restore the previous Go installation, if available; --dry-run only previews the swap'
complete -c gos -n '__gos_needs_command' -a 'uninstall' -d 'Remove an installed version (side-by-side mode); --inactive removes all but the active and rollback'
complete -c gos -n '__gos_needs_command' -a 'use' -d 'Install the Go version requested by .go-version, .tool-versions, or go.mod; --print only resolves it'
complete -c gos -n '__gos_needs_command' -a 'pin' -d 'Write .go-version in the current directory (active version by default)'
complete -c gos -n '__gos_needs_command' -a 'run' -d 'Run a command with a side-by-side Go version without activating it globally; a bare -- uses the project version'
complete -c gos -n '__gos_needs_command' -a 'each' -d 'Run a command against several side-by-side Go versions and report a pass/fail summary'
complete -c gos -n '__gos_needs_command' -a 'check' -d 'Check whether newer stable Go or gos releases are available (no install)'
complete -c gos -n '__gos_needs_command' -a 'current' -d 'Show the currently active Go version'
complete -c gos -n '__gos_needs_command' -a 'list' -d 'List available Go versions (or locally installed ones); --minor keeps the newest per minor'
complete -c gos -n '__gos_needs_command' -a 'platforms' -d 'List supported OS/arch archives for a Go version'
complete -c gos -n '__gos_needs_command' -a 'status' -d 'Show an offline dashboard for gos and the active Go'
complete -c gos -n '__gos_needs_command' -a 'which' -d 'Show the active or side-by-side Go binary path'
complete -c gos -n '__gos_needs_command' -a 'prune' -d 'Remove cached Go archives; --rollback also removes the rollback copy, --dry-run only previews'
complete -c gos -n '__gos_needs_command' -a 'doctor' -d 'Diagnose gos, Go, PATH, and local tool dependencies; --fix creates safe missing directories and prints the shell setup line'
complete -c gos -n '__gos_needs_command' -a 'env' -d 'Print the PATH setup line or an opt-in per-shell auto-switch hook'
complete -c gos -n '__gos_needs_command' -a 'completions' -d 'Print a Bash, Zsh, or Fish completion script (or install it with --install)'
complete -c gos -n '__gos_needs_command' -a 'self-update' -d 'Update gos itself to the latest verified release'
complete -c gos -n '__gos_needs_command' -a 'version' -d 'Show gos version'
complete -c gos -n '__gos_needs_command' -a 'help' -d 'Show this help message, or usage for one command'
# gos-commands:fish:end
# --json only where gos actually supports it (leading flag or per command).
complete -c gos -n '__gos_needs_command' -l json -d 'Output machine-readable JSON where supported'
complete -c gos -n '__gos_using_command check current list platforms status which doctor prune env version use' -l json -d 'Output machine-readable JSON'
complete -c gos -n '__gos_using_command prune' -l rollback -d 'Also remove the rollback installation'
complete -c gos -n '__gos_using_command prune' -l dry-run -d 'Preview removals without deleting'
complete -c gos -n '__gos_using_command rollback' -l dry-run -d 'Preview the rollback without switching'
complete -c gos -n '__gos_using_command doctor' -l fix -d 'Apply safe non-destructive fixes'
complete -c gos -n '__gos_using_command use' -l print -d 'Only resolve the project version'
complete -c gos -n '__gos_using_command help' -a '(gos __commands 2>/dev/null)' -d 'gos command'
complete -c gos -n '__gos_using_command list' -l installed -d 'List locally installed versions'
complete -c gos -n '__gos_using_command list' -l minor -d 'Keep only the newest version per minor'
complete -c gos -n '__gos_using_command install platforms' -a '(gos __versions --remote-cached 2>/dev/null)' -d 'Go version'
complete -c gos -n '__gos_using_command run each; and __gos_wants_version' -a '(gos __versions --remote-cached 2>/dev/null)' -d 'Go version'
complete -c gos -n '__gos_using_command run; and __gos_wants_version' -a -- -d 'Use the project Go version'
complete -c gos -n '__gos_using_command run each; and not __gos_wants_version' -a '(__gos_complete_command)'
complete -c gos -n '__gos_using_command pin' -a '(gos __versions 2>/dev/null)' -d 'Installed Go version'
complete -c gos -n '__gos_using_command uninstall which' -a '(gos __versions 2>/dev/null)' -d 'Installed Go version'
complete -c gos -n '__gos_using_command uninstall' -l inactive -d 'Remove all inactive versions'
complete -c gos -n '__gos_using_command uninstall' -l dry-run -d 'Preview removals without deleting'
complete -c gos -n '__gos_using_command env' -l fish -d 'Emit fish shell syntax'
complete -c gos -n '__gos_using_command env' -l auto -d 'Emit opt-in auto-switch hook'
complete -c gos -n '__gos_using_command use' -a '(__fish_complete_directories)' -d 'Project directory'
complete -c gos -n '__gos_using_command completions' -a 'bash zsh fish' -d 'Shell'
complete -c gos -n '__gos_using_command completions' -l install -d 'Write the completion to the standard per-user directory'
