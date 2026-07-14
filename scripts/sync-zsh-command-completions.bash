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

# Ruby is already used by repo validation scripts. Generating the _describe
# entries here keeps zsh escaping centralized and tied to gos's manifest.
ruby -EUTF-8 - "$mode" <<'RUBY'
mode = ARGV.fetch(0)

MARKER_BEGIN = "  # gos-commands:zsh:begin"
MARKER_END = "  # gos-commands:zsh:end"


def fail!(message)
  warn message
  exit 1
end


def zsh_single_quote(value)
  "'#{value.gsub('\\', '\\\\').gsub("'", "'\\\\''")}'"
end

details = `bash gos.sh __commands --details 2>&1`
fail!("gos __commands --details failed:\n#{details}") unless $?.success?

entries = details.lines.map.with_index(1) do |line, index|
  fields = line.chomp.split("|", 3)
  fail!("invalid command detail line #{index}: #{line.inspect}") unless fields.length == 3
  name, _usage, description = fields
  fail!("empty command detail field on line #{index}: #{line.inspect}") if name.empty? || description.empty?

  "    #{zsh_single_quote("#{name}:#{description}")}"
end
fail!("gos __commands --details returned no commands") if entries.empty?

block = ([MARKER_BEGIN, "  commands=("] + entries + ["  )", MARKER_END, ""]).join("\n")

current = File.read("completions/gos.zsh")
pattern = /^#{Regexp.escape(MARKER_BEGIN)}\n.*?^#{Regexp.escape(MARKER_END)}\n/m
fail!("Zsh command completion markers were not found") unless current.match?(pattern)

updated = current.sub(pattern, block)
if mode == "--check"
  if current != updated
    warn "Zsh command completions are out of sync; run scripts/sync-zsh-command-completions.bash --write"
    exit 1
  end
else
  File.write("completions/gos.zsh", updated)
end
RUBY
