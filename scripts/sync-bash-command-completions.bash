#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s [--check|--write]\n' "${0##*/}" >&2
}

mode="${1:---check}"
if [ "$#" -gt 1 ]; then
  usage
  exit 2
fi
case "$mode" in
  --check | --write) ;;
  *)
    usage
    exit 2
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Ruby is already used by repo validation scripts. The Bash completion only
# needs a generated fallback word list for environments where gos itself is not
# available while completion loads.
ruby -EUTF-8 - "$mode" <<'RUBY'
mode = ARGV.fetch(0)

MARKER_BEGIN = "  # gos-commands:bash:begin"
MARKER_END = "  # gos-commands:bash:end"


def fail!(message)
  warn message
  exit 1
end

commands_output = `bash gos.sh __commands 2>&1`
fail!("gos __commands failed:\n#{commands_output}") unless $?.success?
commands = commands_output.lines.map(&:strip).reject(&:empty?)
fail!("gos __commands returned no commands") if commands.empty?

fallback_commands = commands.join(" ")
fail!("command list contains a double quote") if fallback_commands.include?("\"")

block = [
  MARKER_BEGIN,
  "  local fallback_commands=\"#{fallback_commands}\"",
  MARKER_END,
  ""
].join("\n")

current = File.read("completions/gos.bash")
pattern = /^#{Regexp.escape(MARKER_BEGIN)}\n.*?^#{Regexp.escape(MARKER_END)}\n/m
fail!("Bash command fallback markers were not found") unless current.match?(pattern)

updated = current.sub(pattern, block)
if mode == "--check"
  if current != updated
    warn "Bash command fallback is out of sync; run scripts/sync-bash-command-completions.bash --write"
    exit 1
  end
else
  File.write("completions/gos.bash", updated)
end
RUBY
