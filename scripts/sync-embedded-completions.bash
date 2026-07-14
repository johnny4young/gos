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

# Ruby is already used by repo validation scripts. Keeping the larger text
# rewrite in Ruby avoids fragile sed escaping for completion bodies containing
# backslashes, quotes, and shell metacharacters.
ruby -EUTF-8 - "$mode" <<'RUBY'
mode = ARGV.fetch(0)

EXTENSION = {
  "bash" => "bash",
  "zsh" => "zsh",
  "fish" => "fish"
}.freeze

def completion_block(shell)
  path = "completions/gos.#{EXTENSION.fetch(shell)}"
  body = File.read(path)
  body = body.sub(/\n*\z/, "\n")
  delimiter = "GOS_COMPLETION_#{shell.upcase}"

  [
    "# gos-completions:#{shell}:begin",
    "_gos_completion_#{shell}() {",
    "  cat <<'#{delimiter}'",
    body.chomp,
    delimiter,
    "}",
    "# gos-completions:#{shell}:end",
    ""
  ].join("\n")
end

updated = File.read("gos.sh")
EXTENSION.each_key do |shell|
  marker = Regexp.escape(shell)
  pattern = /^# gos-completions:#{marker}:begin\n.*?^# gos-completions:#{marker}:end\n/m
  unless updated.match?(pattern)
    warn "embedded #{shell} completion block was not found in gos.sh"
    exit 1
  end

  updated = updated.sub(pattern, completion_block(shell))
end

current = File.read("gos.sh")
if mode == "--check"
  if current != updated
    warn "embedded completions are out of sync; run scripts/sync-embedded-completions.bash --write"
    exit 1
  end
else
  File.write("gos.sh", updated)
end
RUBY
