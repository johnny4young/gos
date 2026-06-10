# Fish completion for gos

complete -c gos -f
complete -c gos -n '__fish_use_subcommand' -a 'latest'  -d 'Install the latest stable Go version'
complete -c gos -n '__fish_use_subcommand' -a 'install'  -d 'Install a specific Go version'
complete -c gos -n '__fish_use_subcommand' -a 'use'      -d 'Install the Go version requested by .go-version or go.mod'
complete -c gos -n '__fish_use_subcommand' -a 'pin'      -d 'Write .go-version in the current directory'
complete -c gos -n '__fish_use_subcommand' -a 'rollback' -d 'Restore the previous Go installation'
complete -c gos -n '__fish_use_subcommand' -a 'prune'    -d 'Remove cached Go archives and optionally the rollback copy'
complete -c gos -n '__fish_use_subcommand' -a 'current'  -d 'Show the currently active Go version'
complete -c gos -n '__fish_use_subcommand' -a 'list'     -d 'List all available Go versions'
complete -c gos -n '__fish_use_subcommand' -a 'platforms' -d 'List supported OS/arch archives for a Go version'
complete -c gos -n '__fish_use_subcommand' -a 'doctor'   -d 'Diagnose gos, Go, PATH, and tool dependencies'
complete -c gos -n '__fish_use_subcommand' -a 'version'  -d 'Show gos version'
complete -c gos -n '__fish_use_subcommand' -a 'help'     -d 'Show help message'
complete -c gos -l json -d 'Output machine-readable JSON where supported'
