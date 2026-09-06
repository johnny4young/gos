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
env_details = `bash gos.sh __env 2>&1`
fail!("gos __env failed:\n#{env_details}") unless $?.success?
env_details.lines.each_with_index do |line, index|
  fields = line.chomp.split("|", 4)
  fail!("invalid environment manifest line #{index + 1}: #{line.inspect}") unless fields.length == 4
  name, readers, default, description = fields
  next unless readers.split(",").include?("gos")

  lines << ".TP"
  lines << ".B #{name}"
  lines << "\\&#{man(description)} Default: #{man(default)}."
end
lines << ".SH EXIT STATUS"
lines << "0 on success, 1 on a generic failure, 2 for invalid arguments or configuration, 3 when a download or feed fetch failed, 4 when a checksum or release could not be verified, and 5 when another gos holds the mutation lock. With \\fB\\-\\-json\\fR a failed command prints one {\"error\":{\"code\":...,\"message\":...}} document on standard output. The doctor command keeps its diagnostic report and exits 1 when it reports problems; invalid doctor arguments still produce a usage error document."
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
