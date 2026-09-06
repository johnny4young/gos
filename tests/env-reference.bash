#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

ruby -EUTF-8 <<'RUBY'
require "json"
require "open3"
require "tmpdir"
require "fileutils"

def assert(condition, message)
  abort "not ok - #{message}" unless condition
end

def run!(*args)
  out, err, status = Open3.capture3(*args)
  assert(status.success?, "#{args.inspect}: #{out}#{err}")
  out
end

raw = run!("bash", "gos.sh", "__env", "--json")
document = JSON.parse(raw)
assert(document.keys == ["variables"], "__env JSON root schema")
variables = document.fetch("variables")
assert(variables.is_a?(Array) && !variables.empty?, "__env nonempty variable array")
allowed_readers = %w[gos install.sh install.ps1 packaging/windows/uninstall.ps1]
variables.each do |row|
  assert(row.keys.sort == %w[default description name readers], "__env entry schema")
  assert(%w[name default description].all? { |k| row[k].is_a?(String) && !row[k].empty? }, "__env string fields")
  assert(row["name"].match?(/\A[A-Z][A-Z0-9_]*\z/), "__env variable name")
  readers = row["readers"]
  assert(readers.is_a?(Array) && !readers.empty? && readers.uniq == readers && (readers - allowed_readers).empty?, "__env reader array")
end
by_name = variables.to_h { |row| [row.fetch("name"), row] }
assert(by_name.size == variables.size, "__env names must be unique")
text_rows = run!("bash", "gos.sh", "__env").lines.map { |line| line.chomp.split("|", -1) }
assert(text_rows == variables.map { |r| [r["name"], r["readers"].join(","), r["default"], r["description"]] }, "text/JSON environment parity")
assert(by_name.fetch("GOS_HOME").fetch("default") == '%LOCALAPPDATA%\Programs\gos', "Windows default must preserve literal backslashes")
assert(by_name.fetch("GOS_REQUIRE_CHECKSUM").fetch("readers") == %w[gos install.sh], "checksum readers")
assert(by_name.fetch("GOS_HOME").fetch("readers") == %w[install.ps1 packaging/windows/uninstall.ps1], "Windows install/uninstall readers")
assert(by_name.fetch("NO_COLOR").fetch("description").include?("non-empty"), "NO_COLOR documentation must match implementation")
%w[--bogus positional].each do |arg|
  out, _err, status = Open3.capture3("bash", "gos.sh", "__env", arg, "--json")
  assert(status.exitstatus == 2 && JSON.parse(out).fetch("error").fetch("code") == "usage", "invalid __env args must produce usage JSON")
end
assert(!run!("bash", "gos.sh", "__commands").lines.map(&:strip).include?("__env"), "__env stays hidden")

# Cover each reader, not a hand-maintained list of installer variable names.
internal = %w[GOS_ACTIVATION_BACKUP GOS_COMPLETED_PARTIAL GOS_EXIT_CLASS GOS_FEED_PARSER GOS_LAST_ERROR GOS_OUTPUT_JSON GOS_RELEASE_BASE_URL GOS_VERSION GOS_EXPECTED_SHA256 GOS_RELEASE_TAG GOS_SCRIPT_URL GOS_TMP_DIR]
{ "gos" => "gos.sh", "install.sh" => "install.sh", "install.ps1" => "install.ps1", "packaging/windows/uninstall.ps1" => "packaging/windows/uninstall.ps1" }.each do |reader, path|
  source = File.read(path)
  names = if path.end_with?(".ps1")
    source.scan(/\$env:(GOS_[A-Z0-9_]+)/i).flatten.map(&:upcase)
  else
    source.scan(/\$\{(GOS_[A-Z0-9_]+|NO_COLOR|TERM|XDG_[A-Z0-9_]+|GOTOOLCHAIN)[:}+\-]/).flatten
  end
  names.uniq.each do |name|
    next if internal.include?(name) || name.start_with?("GOS_AUTO_", "GOS_DOCTOR_")
    assert(by_name.fetch(name).fetch("readers").include?(reader), "#{path} reader missing for #{name}")
  end
end
man = File.read("docs/gos.1")
variables.each do |row|
  present = man.lines.include?(".B #{row['name']}\n")
  assert(present == row["readers"].include?("gos"), "man-page reader filter for #{row['name']}")
end
puts "ok - environment JSON schema, text parity, reader coverage, escaping and man-page scope"

Dir.mktmpdir("gos-env-reference") do |dir|
  FileUtils.mkdir_p(File.join(dir, "scripts"))
  FileUtils.cp("scripts/sync-readme-env.bash", File.join(dir, "scripts"))
  source = File.read("gos.sh")
  fixture = 'GOS_TEST_DOCS|gos|a`b|go<version> & <script> *stars* [label] `ticks` gos completions bash --install'
  source.sub!("GOS_ENV\n}", "#{fixture}\nGOS_ENV\n}")
  File.write(File.join(dir, "gos.sh"), source)
  target = File.join(dir, "README.md")
  File.write(target, "before\n<!-- gos-env:begin -->\nold\n<!-- gos-env:end -->\nafter\n")
  generator = File.join(dir, "scripts/sync-readme-env.bash")
  run!("bash", generator, "--write")
  rendered = File.read(target)
  assert(rendered.include?('go&lt;version&gt; &amp; &lt;script&gt; \*stars\* \[label\] \`ticks\`'), "description Markdown/HTML escaping")
  assert(rendered.include?('`` a`b ``'), "code defaults containing backticks")
  assert(!rendered.include?('gos completions bash `--install`'), "no nested option code spans")
  assert(rendered.start_with?("before\n") && rendered.end_with?("after\n"), "generator preserves surrounding content")
  run!("bash", generator, "--check")
  run!("bash", generator, "--write")
  assert(File.read(target) == rendered, "generator idempotence")
  [rendered.sub("<!-- gos-env:end -->", "missing"), rendered + "<!-- gos-env:begin -->\n"].each do |invalid|
    File.write(target, invalid)
    _out, _err, status = Open3.capture3("bash", generator, "--write")
    assert(!status.success? && File.read(target) == invalid, "bad markers must fail without rewriting README")
  end
end
puts "ok - environment renderer escapes fixture metacharacters and rejects ambiguous markers"
readme = File.read("README.md")
assert(readme.index("### Optional: remove managed Go data first") < readme.index("### Remove the gos command"), "managed cleanup precedes command removal")
preview = readme.match(/```bash\n(# gos-uninstall:preview\n.*?)\n```/m)[1]
cleanup = readme.match(/```bash\n(# gos-uninstall:data\n.*?)\n```/m)[1]
# Execute the published snippets with shell-function doubles: never remove
# actual installations, invoke sudo, or depend on the user's configuration.
doubles = <<~'BASH'
  log_cmd() { printf '<%s>' "$@"; printf '\n'; }
  gos() { log_cmd gos "$@"; }
  rm() { log_cmd rm "$@"; }
  rmdir() { log_cmd rmdir "$@"; }
BASH
Dir.mktmpdir("gos-uninstall-docs") do |dir|
  home = File.join(dir, "home with spaces")
  FileUtils.mkdir_p(home)
  empty = %w[GOS_INSTALL_DIR GOS_VERSIONS_DIR GOS_CACHE_DIR XDG_CACHE_HOME XDG_DATA_HOME XDG_CONFIG_HOME].to_h { |name| [name, nil] }
  cases = [
    [empty.merge("HOME" => home), "/usr/local/go", nil, "#{home}/.cache/gos", "#{home}/.local/share", "#{home}/.config"],
    [empty.merge("HOME" => home, "GOS_INSTALL_DIR" => "#{home}/active go/", "GOS_VERSIONS_DIR" => "#{home}/versions [all]/", "GOS_CACHE_DIR" => "#{home}/archive cache", "XDG_DATA_HOME" => "#{home}/data", "XDG_CONFIG_HOME" => "#{home}/config"), "#{home}/active go", "#{home}/versions [all]", "#{home}/archive cache", "#{home}/data", "#{home}/config"],
    [empty.merge("HOME" => home, "XDG_CACHE_HOME" => "#{home}/xdg cache"), "/usr/local/go", nil, "#{home}/xdg cache/gos", "#{home}/.local/share", "#{home}/.config"]
  ]
  cases.each do |env, install, versions, cache, data, config|
    FileUtils.mkdir_p(cache)
    output = run!(env, "bash", "-c", doubles + preview + "\n" + cleanup)
    assert(output.include?("<rm><-ri><--><#{install}>"), "uninstall uses exact install path without trailing slash")
    assert(versions.nil? || output.include?("<rm><-ri><--><#{versions}>"), "uninstall uses configured versions path")
    assert(!versions.nil? || !output.include?("<rm><-ri><--><#{home}/.gos/versions>"), "no guessed versions directory")
    assert(output.include?("<rmdir><--><#{cache}>"), "uninstall only removes empty effective cache")
    assert(output.include?("<#{data}/bash-completion/completions/gos><#{data}/zsh/site-functions/_gos><#{config}/fish/completions/gos.fish>"), "completion cleanup honors XDG overrides")
    assert(output.index("<gos><prune><--rollback>\n") < output.index("<rm>"), "prune executes before installation removal")
    assert(!output.include?("<-rf>"), "documentation must not recursively force-delete custom directories")
  end
end
assert(readme.include?('${GOS_BIN_DIR:-/usr/local/bin}/gos'), "command cleanup honors GOS_BIN_DIR")
assert(readme.include?('$gosHome = $env:GOS_HOME') && readme.include?('-InstallDir $gosHome'), "Windows cleanup passes the configured original installation")
assert(!readme.include?("checks every item below"), "doctor claims must match diagnostic scope")
assert(readme.include?('${GOS_INSTALL_DIR:-/usr/local/go}.gos-lock'), "lock advice uses the effective install path")
assert(readme.include?('"current":"v1.9.0","latest":"v1.10.0"') && readme.include?('"gos_version":"1.9.0"') && readme.include?('gos updated: v1.9.0 -> v1.10.0'), "version examples agree")
puts "ok - documented uninstall snippets preserve custom paths and safe ordering with mocked deletion"

RUBY
