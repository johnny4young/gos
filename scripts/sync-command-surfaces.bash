#!/usr/bin/env bash
set -euo pipefail

# Regenerate (or verify) every surface derived from gos.sh's manifests:
#   _gos_command_manifest (gos __commands --details) -> completion command
#   lists, the README command table, the man page COMMANDS section
#   _gos_env_manifest (gos __env) -> the README configuration table, the man
#   page ENVIRONMENT section
#   completions/gos.* -> the copies embedded in gos.sh
# One Ruby program holds the target table below; everything is rendered in
# memory first, so --check reports every stale surface at once and --write
# touches the disk only when every target rendered. The Bash wrapper snapshots
# the targets (from the same table) and restores them if the write fails.
#
# Usage: scripts/sync-command-surfaces.bash [--check|--write]
# (--targets, used by the wrapper and the tests, prints the target paths.)

usage() {
  printf 'Usage: %s [--check|--write]\n' "${0##*/}" >&2
}

mode="${1:---check}"
if [ "$#" -gt 1 ]; then
  usage
  exit 2
fi
case "$mode" in
  --check | --write | --targets) ;;
  *)
    usage
    exit 2
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Ruby keeps the rewrites free of sed escaping; it is already required by the
# workflow invariant tests.
run_sync() {
  ruby -EUTF-8 - "$@" <<'RUBY'
mode = ARGV.fetch(0)


def fail!(message)
  warn message
  exit 1
end


def capture(command)
  output = `#{command} 2>&1`
  fail!("#{command} failed:\n#{output}") unless $?.success?
  output
end


def parse_fields(output, count, what)
  rows = output.lines.map.with_index(1) do |line, index|
    fields = line.chomp.split("|", count)
    fail!("invalid #{what} line #{index}: #{line.inspect}") unless fields.length == count
    fail!("empty #{what} field on line #{index}: #{line.inspect}") if fields.any?(&:empty?)
    fields
  end
  fail!("#{what} is empty") if rows.empty?
  rows
end

# --- quoting helpers per surface -------------------------------------------

def fish_single_quote(value)
  "'#{value.gsub('\\', '\\\\').gsub("'", "\\\\'")}'"
end


def zsh_single_quote(value)
  "'#{value.gsub('\\', '\\\\').gsub("'", "'\\\\''")}'"
end


def markdown_cell(value)
  value.gsub("|", "\\|")
end


def markdown_command_description(value)
  markdown_cell(value)
    .gsub(/(?<![\w`])(--[A-Za-z0-9-]+)/, '`\\1`')
    .gsub(/(?<![\w`])(\.(?:go-version|tool-versions))(?![\w`])/, '`\\1`')
    .gsub(/(?<![\w`])(go\.mod)(?![\w`])/, '`\\1`')
end


# Environment descriptions are plain text, not Markdown. Escape once rather
# than running overlapping code-span substitutions (whole commands can
# contain options).
def env_markdown_cell(value)
  value.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
    .gsub(/[\\`*_{}\[\]|]/) { |char| "\\" + char }
end


def markdown_code(value)
  delimiter = "`" * ([1] + value.scan(/`+/).map { |run| run.length + 1 }).max
  padding = delimiter.length > 1 ? " " : ""
  "#{delimiter}#{padding}#{value.gsub("|", "\\|")}#{padding}#{delimiter}"
end


def env_markdown_default(value)
  return env_markdown_cell(value) if value == "unset" || value == "from the terminal"

  value.split(" or ").map { |part| markdown_code(part) }.join(" or ")
end

# troff: the escape character is a backslash, and option double-dashes read
# better as \-\-.
def man(value)
  value.gsub("\\") { '\e' }.gsub("--") { '\-\-' }
end

# --- renderers ---------------------------------------------------------------

def render_bash_commands(commands, _env)
  fallback = commands.map { |c| c[:name] }.join(" ")
  fail!("command list contains a double quote") if fallback.include?("\"")
  ["  local fallback_commands=\"#{fallback}\""]
end


def render_fish_commands(commands, _env)
  commands.map do |c|
    "complete -c gos -n '__gos_needs_command' -a #{fish_single_quote(c[:name])} -d #{fish_single_quote(c[:description])}"
  end
end


def render_zsh_commands(commands, _env)
  ["  commands=("] + commands.map { |c| "    #{zsh_single_quote("#{c[:name]}:#{c[:description]}")}" } + ["  )"]
end


def render_readme_commands(commands, _env)
  ["| Command | Description |", "|---|---|"] + commands.map do |c|
    "| `gos #{markdown_cell(c[:usage])}` | #{markdown_command_description(c[:description])} |"
  end
end


def render_readme_env(_commands, env)
  ["| Variable | Read by | Default | Description |", "|---|---|---|---|"] + env.map do |v|
    readers = v[:scope].split(",").map { |reader| markdown_code(reader) }.join(", ")
    "| `#{v[:name]}` | #{readers} | #{env_markdown_default(v[:default])} | #{env_markdown_cell(v[:description])} |"
  end
end


def render_man_page(commands, env)
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
  commands.each do |c|
    lines << ".TP"
    lines << ".B gos #{man(c[:usage])}"
    lines << "\\&#{man(c[:description])}"
  end
  lines << ".SH ENVIRONMENT"
  env.each do |v|
    next unless v[:scope].split(",").include?("gos")

    lines << ".TP"
    lines << ".B #{v[:name]}"
    lines << "\\&#{man(v[:description])} Default: #{man(v[:default])}."
  end
  lines << ".SH EXIT STATUS"
  lines << "0 on success, 1 on a generic failure, 2 for invalid arguments or configuration, 3 when a download or feed fetch failed, 4 when a checksum or release could not be verified, and 5 when another gos holds the mutation lock. With \\fB\\-\\-json\\fR a failed command prints one {\"error\":{\"code\":...,\"message\":...}} document on standard output. The doctor command keeps its diagnostic report and exits 1 when it reports problems; invalid doctor arguments still produce a usage error document."
  lines << ".SH SEE ALSO"
  lines << ".BR go (1)"
  lines << ".SH HOMEPAGE"
  lines << "https://github.com/johnny4young/gos"
  lines
end

# Embedded copies of the (already regenerated, in-memory) completion files.
def embed_completion(contents, shell)
  body = contents.fetch("completions/gos.#{shell}").sub(/\n*\z/, "\n")
  delimiter = "GOS_COMPLETION_#{shell.upcase}"
  ["_gos_completion_#{shell}() {", "  cat <<'#{delimiter}'", body.chomp, delimiter, "}"]
end

# --- the target table ----------------------------------------------------------
# Each target is one marked block (or a whole file) in one path. Blocks are
# replaced in order; the embedded completions come last so they see the
# regenerated completion files. A path may appear more than once.
TARGETS = [
  { path: "completions/gos.bash", begin: "  # gos-commands:bash:begin", end: "  # gos-commands:bash:end", render: :bash_commands, what: "Bash command fallback" },
  { path: "completions/gos.fish", begin: "# gos-commands:fish:begin", end: "# gos-commands:fish:end", render: :fish_commands, what: "Fish command completions" },
  { path: "completions/gos.zsh", begin: "  # gos-commands:zsh:begin", end: "  # gos-commands:zsh:end", render: :zsh_commands, what: "Zsh command completions" },
  { path: "README.md", begin: "<!-- gos-commands:begin -->", end: "<!-- gos-commands:end -->", render: :readme_commands, what: "README Usage command table" },
  { path: "README.md", begin: "<!-- gos-env:begin -->", end: "<!-- gos-env:end -->", render: :readme_env, what: "README configuration table" },
  { path: "docs/gos.1", whole_file: true, render: :man_page, what: "man page" },
  { path: "gos.sh", begin: "# gos-completions:bash:begin", end: "# gos-completions:bash:end", embed: "bash", what: "embedded bash completion block" },
  { path: "gos.sh", begin: "# gos-completions:zsh:begin", end: "# gos-completions:zsh:end", embed: "zsh", what: "embedded zsh completion block" },
  { path: "gos.sh", begin: "# gos-completions:fish:begin", end: "# gos-completions:fish:end", embed: "fish", what: "embedded fish completion block" }
].freeze

if mode == "--targets"
  puts TARGETS.map { |t| t[:path] }.uniq
  exit 0
end

commands = parse_fields(capture("bash gos.sh __commands --details"), 3, "command manifest").map do |name, usage, description|
  { name: name, usage: usage, description: description }
end
env = parse_fields(capture("bash gos.sh __env"), 4, "environment manifest").map do |name, scope, default, description|
  { name: name, scope: scope, default: default, description: description }
end

contents = Hash.new { |hash, path| hash[path] = File.exist?(path) ? File.read(path) : "" }
TARGETS.each do |target|
  path = target[:path]
  if target[:whole_file]
    contents[path] = send("render_#{target[:render]}", commands, env).join("\n") + "\n"
    next
  end
  block_lines = target[:embed] ? embed_completion(contents, target[:embed]) : send("render_#{target[:render]}", commands, env)
  block = ([target[:begin]] + block_lines + [target[:end], ""]).join("\n")
  [target[:begin], target[:end]].each do |marker|
    count = contents[path].lines.count { |line| line.chomp == marker }
    fail!("#{target[:what]} was not found in #{path}") if count.zero?
    fail!("#{path} must contain exactly one #{marker.strip} marker (found #{count})") if count > 1
  end
  pattern = /^#{Regexp.escape(target[:begin])}\n.*?^#{Regexp.escape(target[:end])}\n/m
  fail!("#{target[:what]} was not found in #{path}") unless contents[path].match?(pattern)
  # Block form: a string replacement would interpret \\` and \\& in the rendered text.
  contents[path] = contents[path].sub(pattern) { block }
end

stale = TARGETS.map { |t| t[:path] }.uniq.select do |path|
  (File.exist?(path) ? File.read(path) : "") != contents[path]
end

if mode == "--check"
  stale.each { |path| warn "#{path} is out of sync; run scripts/sync-command-surfaces.bash --write" }
  exit 1 unless stale.empty?
else
  stale.each { |path| File.write(path, contents[path]) }
end
RUBY
}

if [ "$mode" = "--targets" ]; then
  run_sync --targets
  exit 0
fi

transaction_dir=""
transaction_committed=0
transaction_targets=()
# A substitution inside the read loop's heredoc hides the producer's status.
# Capture first, and never write from a partial or empty snapshot target list.
if ! target_list="$(run_sync --targets)"; then
  printf 'could not discover command surface targets; refusing to sync\n' >&2
  exit 1
fi
while IFS= read -r target; do
  # Ruby on Windows writes CRLF; the paths must not carry the CR.
  target="${target%$'\r'}"
  [ -n "$target" ] || continue
  transaction_targets=(${transaction_targets[@]:+"${transaction_targets[@]}"} "$target")
done <<EOF_TARGETS
$target_list
EOF_TARGETS
if [ "${#transaction_targets[@]}" -eq 0 ]; then
  printf 'command surface target list is empty; refusing to sync\n' >&2
  exit 1
fi

finish_transaction() {
  transaction_committed=1
}

cleanup_transaction() {
  local exit_status="$1" file restore_failed=0

  trap - EXIT INT TERM
  if [ -n "$transaction_dir" ] && [ "$transaction_committed" -eq 0 ]; then
    for file in "${transaction_targets[@]}"; do
      if ! cp -p "${transaction_dir}/${file}" "$file"; then
        printf 'failed to restore command surface after sync failure: %s\n' "$file" >&2
        restore_failed=1
      fi
    done
    if [ "$restore_failed" -eq 0 ]; then
      printf 'rolled back command surface changes after sync failure\n' >&2
    fi
  fi

  if [ -n "$transaction_dir" ]; then
    rm -rf "$transaction_dir"
  fi
  if [ "$restore_failed" -ne 0 ]; then
    exit 1
  fi
  exit "$exit_status"
}

if [ "$mode" = "--write" ]; then
  transaction_dir="$(mktemp -d)"
  for file in "${transaction_targets[@]}"; do
    if ! mkdir -p "${transaction_dir}/$(dirname "$file")" || ! cp -p "$file" "${transaction_dir}/${file}"; then
      rm -rf "$transaction_dir"
      exit 1
    fi
  done
  trap 'cleanup_transaction "$?"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
fi

run_sync "$mode"

finish_transaction
