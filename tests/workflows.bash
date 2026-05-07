#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

ruby <<'RUBY'
require "yaml"

def fail!(message)
  warn "not ok - #{message}"
  exit 1
end

def assert(condition, message)
  fail!(message) unless condition
end

def workflow(path)
  YAML.load_file(path)
rescue Psych::Exception => error
  fail!("#{path} is not valid YAML: #{error.message}")
end

def workflow_on(config)
  config["on"] || config[true] || {}
end

release = workflow(".github/workflows/release.yml")
ci = workflow(".github/workflows/ci.yml")

release_on = workflow_on(release)
assert(release_on.dig("workflow_dispatch", "inputs", "version"), "release workflow must keep workflow_dispatch version input")

release_jobs = release.fetch("jobs") { fail!("release workflow must define jobs") }
smoke_steps = release_jobs.dig("smoke-test", "steps") || []
smoke_runs = smoke_steps.map { |step| step["run"].to_s }
assert(smoke_runs.any? { |run| run.include?("./gos.sh version") }, "release smoke-test must run gos version")
assert(smoke_runs.any? { |run| run.include?("./gos.sh help") }, "release smoke-test must run gos help")

release_steps = release_jobs.dig("release", "steps") || []
release_uses = release_steps.map { |step| step["uses"].to_s }
assert(release_uses.include?("softprops/action-gh-release@v3"), "release workflow must use softprops/action-gh-release@v3")

release_files = release_steps
  .map { |step| step.dig("with", "files").to_s }
  .join("\n")
%w[gos.sh install.sh checksums.txt].each do |asset|
  assert(release_files.include?(asset), "release workflow must upload #{asset}")
end

ci_on = workflow_on(ci)
assert(ci_on.key?("pull_request"), "CI must run on pull_request")
assert(ci_on.dig("push", "branches")&.include?("main"), "CI must run on pushes to main")
assert(ci.dig("permissions", "contents") == "read", "CI must use read-only contents permission")
assert(ci.dig("defaults", "run", "shell") == "bash", "CI must default to bash shell")

ci_jobs = ci.fetch("jobs") { fail!("CI must define jobs") }
%w[shellcheck smoke workflow-validation].each do |job|
  assert(ci_jobs.key?(job), "CI must define #{job} job")
end

shellcheck_runs = ci_jobs.dig("shellcheck", "steps").map { |step| step["run"].to_s }.join("\n")
assert(shellcheck_runs.include?("shellcheck gos.sh install.sh completions/gos.bash tests/*.bash"), "ShellCheck job must cover scripts and tests")

matrix_os = ci_jobs.dig("smoke", "strategy", "matrix", "os") || []
%w[ubuntu-latest macos-latest windows-latest].each do |os|
  assert(matrix_os.include?(os), "smoke matrix must include #{os}")
end

smoke_runs = ci_jobs.dig("smoke", "steps").map { |step| step["run"].to_s }.join("\n")
smoke_steps = ci_jobs.dig("smoke", "steps")
install_completion_shells = smoke_steps.find { |step| step["name"] == "Install completion shells" }
assert(install_completion_shells, "smoke job must install completion shells")
assert(install_completion_shells["if"] == "runner.os == 'Linux'", "completion shell install must run on Linux")
install_completion_shells_run = install_completion_shells["run"].to_s
assert(install_completion_shells_run.include?("sudo apt-get install -y zsh fish"), "completion shell install must install zsh and fish")

fish_completion = smoke_steps.find { |step| step["name"] == "Fish completion syntax" }
assert(fish_completion, "smoke job must define Fish completion syntax step")
assert(fish_completion["if"] == "runner.os == 'Linux'", "Fish completion syntax must run on Linux")
assert(!fish_completion["run"].to_s.include?("skipping"), "Fish completion syntax must not be optional once fish is installed")

[
  "bash tests/checksum.bash",
  "bash tests/install-transaction.bash",
  "./gos.sh version",
  "./gos.sh help",
  "zsh -n completions/gos.zsh",
  "fish --no-config --no-execute completions/gos.fish"
].each do |command|
  assert(smoke_runs.include?(command), "smoke job must run #{command}")
end

puts "ok - workflow YAML and invariants"
RUBY
