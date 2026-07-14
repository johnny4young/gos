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

# Ruby is already required by the workflow invariant tests. Keeping the
# Markdown rewrite in Ruby avoids fragile sed escaping for command usages and
# descriptions that contain shell metacharacters.
ruby -EUTF-8 - "$mode" <<'RUBY'
mode = ARGV.fetch(0)

MARKER_BEGIN = "<!-- gos-commands:begin -->"
MARKER_END = "<!-- gos-commands:end -->"


def fail!(message)
  warn message
  exit 1
end


def markdown_cell(value)
  value.gsub("|", "\\|")
end


def markdown_description(value)
  markdown_cell(value)
    .gsub(/(?<![\w`])(--[A-Za-z0-9-]+)/, '`\\1`')
    .gsub(/(?<![\w`])(\.(?:go-version|tool-versions))(?![\w`])/, '`\\1`')
    .gsub(/(?<![\w`])(go\.mod)(?![\w`])/, '`\\1`')
end

details = `bash gos.sh __commands --details 2>&1`
fail!("gos __commands --details failed:\n#{details}") unless $?.success?

commands = details.lines.map.with_index(1) do |line, index|
  fields = line.chomp.split("|", 3)
  fail!("invalid command detail line #{index}: #{line.inspect}") unless fields.length == 3
  name, usage, description = fields
  fail!("empty command detail field on line #{index}: #{line.inspect}") if [name, usage, description].any?(&:empty?)

  { name: name, usage: usage, description: description }
end
fail!("gos __commands --details returned no commands") if commands.empty?

block = ([
  MARKER_BEGIN,
  "| Command | Description |",
  "|---|---|"
] + commands.map do |command|
  "| `gos #{markdown_cell(command.fetch(:usage))}` | #{markdown_description(command.fetch(:description))} |"
end + [MARKER_END, ""]).join("\n")

readme = File.read("README.md")
pattern = /^#{Regexp.escape(MARKER_BEGIN)}\n.*?^#{Regexp.escape(MARKER_END)}\n/m
fail!("README Usage command table markers were not found") unless readme.match?(pattern)

updated = readme.sub(pattern, block)
if mode == "--check"
  if readme != updated
    warn "README Usage command table is out of sync; run scripts/sync-readme-usage.bash --write"
    exit 1
  end
else
  File.write("README.md", updated)
end
RUBY
