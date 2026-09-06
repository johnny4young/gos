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

# The README configuration table comes from gos's own environment manifest
# (gos __env), so a variable cannot be read by the script and missing from
# the docs. Ruby keeps the Markdown rewrite free of sed escaping.
ruby -EUTF-8 - "$mode" <<'RUBY'
mode = ARGV.fetch(0)

MARKER_BEGIN = "<!-- gos-env:begin -->"
MARKER_END = "<!-- gos-env:end -->"


def fail!(message)
  warn message
  exit 1
end


# Descriptions are plain text, not Markdown. Escape once rather than running
# overlapping code-span substitutions (whole commands can contain options).
def markdown_cell(value)
  value.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
    .gsub(/[\\`*_{}\[\]|]/) { |char| "\\" + char }
end


def markdown_code(value)
  delimiter = "`" * ([1] + value.scan(/`+/).map { |run| run.length + 1 }).max
  padding = delimiter.length > 1 ? " " : ""
  "#{delimiter}#{padding}#{value.gsub("|", "\\|")}#{padding}#{delimiter}"
end


def markdown_default(value)
  return markdown_cell(value) if value == "unset" || value == "from the terminal"

  value.split(" or ").map { |part| markdown_code(part) }.join(" or ")
end

details = `bash gos.sh __env 2>&1`
fail!("gos __env failed:\n#{details}") unless $?.success?

variables = details.lines.map.with_index(1) do |line, index|
  fields = line.chomp.split("|", 4)
  fail!("invalid environment manifest line #{index}: #{line.inspect}") unless fields.length == 4
  name, readers, default, description = fields
  fail!("empty environment manifest field on line #{index}: #{line.inspect}") if [name, readers, default, description].any?(&:empty?)

  { name: name, readers: readers.split(","), default: default, description: description }
end
fail!("gos __env returned no variables") if variables.empty?

block = ([
  MARKER_BEGIN,
  "| Variable | Read by | Default | Description |",
  "|---|---|---|---|"
] + variables.map do |variable|
  "| `#{variable.fetch(:name)}` | #{variable.fetch(:readers).map { |reader| markdown_code(reader) }.join(", ")} | #{markdown_default(variable.fetch(:default))} | #{markdown_cell(variable.fetch(:description))} |"
end + [MARKER_END, ""]).join("\n")

readme = File.read("README.md")
[MARKER_BEGIN, MARKER_END].each do |marker|
  fail!("README must contain exactly one #{marker}") unless readme.lines.count { |line| line.chomp == marker } == 1
end
pattern = /^#{Regexp.escape(MARKER_BEGIN)}\n.*?^#{Regexp.escape(MARKER_END)}\n/m
fail!("README configuration table markers were not found") unless readme.match?(pattern)

updated = readme.sub(pattern) { block }
if mode == "--check"
  if readme != updated
    warn "README configuration table is out of sync; run scripts/sync-readme-env.bash --write"
    exit 1
  end
else
  File.write("README.md", updated)
end
RUBY
