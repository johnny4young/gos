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

# Ruby (already required by the workflow invariants) renders the man page from
# the same command manifest that drives help, the README table, and the
# completions, so the COMMANDS section can never drift from them. No date or
# version is embedded, keeping --check reproducible across releases.
ruby -EUTF-8 - "$mode" <<'RUBY'
mode = ARGV.fetch(0)
TARGET = "docs/gos.1"

def fail!(message)
  warn message
  exit 1
end

# troff: the escape character is a backslash, and option double-dashes read
# better as \-\-. Content never starts with a control char, but guard anyway.
def man(value)
  value.gsub("\\") { '\e' }.gsub("--") { '\-\-' }
end

details = `bash gos.sh __commands --details 2>&1`
fail!("gos __commands --details failed:\n#{details}") unless $?.success?

commands = details.lines.map.with_index(1) do |line, index|
  fields = line.chomp.split("|", 3)
  fail!("invalid command detail line #{index}: #{line.inspect}") unless fields.length == 3
  name, usage, description = fields
  fail!("empty command detail field on line #{index}: #{line.inspect}") if [name, usage, description].any?(&:empty?)
  { usage: usage, description: description }
end
fail!("gos __commands --details returned no commands") if commands.empty?

lines = []
lines << '.TH GOS 1 "" "gos" "User Commands"'
lines << ".SH NAME"
lines << 'gos \- install and switch Go versions in seconds'
lines << ".SH SYNOPSIS"
lines << ".B gos"
lines << ".I command"
lines << ".RI [ options ]"
lines << ".SH DESCRIPTION"
lines << "gos (Go Switch) is a single Bash script that installs and switches Go"
lines << "versions. It downloads the official binary from go.dev, verifies its"
lines << "SHA256 checksum, installs it transactionally, and can roll back. It needs"
lines << 'nothing but \fBcurl\fR (or \fBwget\fR) and \fBbash\fR.'
lines << ".SH COMMANDS"
commands.each do |command|
  lines << ".TP"
  lines << ".B gos #{man(command.fetch(:usage))}"
  lines << "\\&#{man(command.fetch(:description))}"
end
lines << ".SH ENVIRONMENT"
[
  ["GOS_INSTALL_DIR", "Where Go is installed (default /usr/local/go). Override to install without sudo."],
  ["GOS_VERSIONS_DIR", "Opt-in side-by-side layout: each version installs under its own directory and the install dir becomes a symlink to the active one."],
  ["GOS_CACHE_DIR", "Where verified archives and the discovery feed cache are stored."],
  ["GOS_DOWNLOAD_MIRROR", "HTTPS base URL to download archives from; checksums are still verified against go.dev."],
  ["GOS_REQUIRE_CHECKSUM", "Set to 1 to fail closed when a checksum cannot be verified, or feed to additionally require the digest to come from the go.dev feed."],
  ["GOS_FEED_TTL", "Seconds to reuse the on-disk discovery feed cache (default 600; 0 disables it)."],
  ["NO_COLOR", "When set, disables colored and symbol output (also GOS_NO_COLOR=1)."],
].each do |name, description|
  lines << ".TP"
  lines << ".B #{name}"
  lines << "\\&#{man(description)}"
end
lines << ".SH SEE ALSO"
lines << ".BR go (1)"
lines << ".SH HOMEPAGE"
lines << "https://github.com/johnny4young/gos"

rendered = lines.join("\n") + "\n"

if mode == "--check"
  current = File.exist?(TARGET) ? File.read(TARGET) : ""
  if current != rendered
    warn "#{TARGET} is out of sync; run scripts/sync-man-page.bash --write"
    exit 1
  end
else
  File.write(TARGET, rendered)
end
RUBY
