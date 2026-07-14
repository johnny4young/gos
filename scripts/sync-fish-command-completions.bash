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

# Ruby is already used by repo validation scripts. Generating this block in
# Ruby keeps Fish single-quote escaping simple and mirrors the README sync
# script's manifest parsing.
ruby -EUTF-8 - "$mode" <<'RUBY'
mode = ARGV.fetch(0)

MARKER_BEGIN = "# gos-commands:fish:begin"
MARKER_END = "# gos-commands:fish:end"


def fail!(message)
  warn message
  exit 1
end


def fish_single_quote(value)
  "'#{value.gsub('\\', '\\\\').gsub("'", "\\\\'")}'"
end

details = `bash gos.sh __commands --details 2>&1`
fail!("gos __commands --details failed:\n#{details}") unless $?.success?

commands = details.lines.map.with_index(1) do |line, index|
  fields = line.chomp.split("|", 3)
  fail!("invalid command detail line #{index}: #{line.inspect}") unless fields.length == 3
  name, _usage, description = fields
  fail!("empty command detail field on line #{index}: #{line.inspect}") if name.empty? || description.empty?

  { name: name, description: description }
end
fail!("gos __commands --details returned no commands") if commands.empty?

block = ([MARKER_BEGIN] + commands.map do |command|
  "complete -c gos -n '__fish_use_subcommand' -a #{fish_single_quote(command.fetch(:name))} -d #{fish_single_quote(command.fetch(:description))}"
end + [MARKER_END, ""]).join("\n")

current = File.read("completions/gos.fish")
pattern = /^#{Regexp.escape(MARKER_BEGIN)}\n.*?^#{Regexp.escape(MARKER_END)}\n/m
fail!("Fish command completion markers were not found") unless current.match?(pattern)

updated = current.sub(pattern, block)
if mode == "--check"
  if current != updated
    warn "Fish command completions are out of sync; run scripts/sync-fish-command-completions.bash --write"
    exit 1
  end
else
  File.write("completions/gos.fish", updated)
end
RUBY
