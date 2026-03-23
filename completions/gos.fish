# Fish completion for gos

complete -c gos -f
complete -c gos -n '__fish_use_subcommand' -a 'latest'  -d 'Install the latest stable Go version'
complete -c gos -n '__fish_use_subcommand' -a 'install'  -d 'Install a specific Go version'
complete -c gos -n '__fish_use_subcommand' -a 'current'  -d 'Show the currently active Go version'
complete -c gos -n '__fish_use_subcommand' -a 'list'     -d 'List all available Go versions'
complete -c gos -n '__fish_use_subcommand' -a 'version'  -d 'Show gos version'
complete -c gos -n '__fish_use_subcommand' -a 'help'     -d 'Show help message'
