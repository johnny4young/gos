# VHS tape for the README demo (https://github.com/charmbracelet/vhs).
#
# Regenerate the animated demo with:
#   vhs docs/demo.tape
#
# The committed docs/demo.png is a static render of this same session; keep
# both in sync when commands or their output change. Run against a sandbox
# so the demo never mutates a real Go installation:
#   export GOS_INSTALL_DIR="$HOME/.gos/go"
#   export GOS_VERSIONS_DIR="$HOME/.gos/versions"

Output docs/demo.gif

Set FontSize 26
Set Width 1552
Set Height 960
Set Theme "GitHub Dark"
Set Padding 20

Type "gos install 1.24.0"
Enter
Sleep 6s

Type "gos run 1.24.0 go version"
Enter
Sleep 2s

Type "gos status"
Enter
Sleep 3s

Sleep 2s
