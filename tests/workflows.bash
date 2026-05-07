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

def job_needs(job)
  needs = job["needs"]
  needs.is_a?(Array) ? needs : [needs].compact
end

def steps_for(jobs, job_name)
  job = jobs.fetch(job_name) { fail!("workflow must define #{job_name} job") }
  job.fetch("steps") { fail!("#{job_name} job must define steps") }
end

def step_named(steps, name)
  steps.find { |step| step["name"] == name }
end

def file_text(path)
  File.file?(path) ? File.read(path) : ""
end

release = workflow(".github/workflows/release.yml")
ci = workflow(".github/workflows/ci.yml")
readme = file_text("README.md")
gos_version = file_text("gos.sh")[/^GOS_VERSION="([^"]+)"$/, 1]
assert(gos_version && !gos_version.empty?, "gos.sh must define GOS_VERSION")

release_on = workflow_on(release)
assert(release_on.dig("workflow_dispatch", "inputs", "version"), "release workflow must keep workflow_dispatch version input")
assert(release.dig("permissions", "contents") == "read", "release workflow must use read-only top-level contents permission")
assert(release.dig("defaults", "run", "shell") == "bash", "release workflow must default to bash shell")

release_jobs = release.fetch("jobs") { fail!("release workflow must define jobs") }
%w[validate-release-ref version-bump smoke-test release update-formula].each do |job|
  assert(release_jobs.key?(job), "release workflow must define #{job} job")
end

validate_job = release_jobs.fetch("validate-release-ref")
assert(validate_job.dig("outputs", "version") == "${{ steps.release-ref.outputs.version }}", "validate-release-ref must expose version output")
assert(validate_job.dig("outputs", "tag") == "${{ steps.release-ref.outputs.tag }}", "validate-release-ref must expose tag output")
validate_steps = steps_for(release_jobs, "validate-release-ref")
validate_step = step_named(validate_steps, "Validate release ref")
assert(validate_step, "validate-release-ref must validate the release ref")
validate_env = validate_step["env"] || {}
assert(validate_env["INPUT_VERSION"].to_s.include?("github.event.inputs.version"), "validate-release-ref must read manual input via env")
assert(validate_env["REF_NAME"].to_s.include?("github.ref_name"), "validate-release-ref must read tag ref via env")
validate_run = validate_step["run"].to_s
[
  "semver_re=",
  "workflow_dispatch)",
  "push)",
  "version=%s",
  "tag=%s",
  "GITHUB_OUTPUT"
].each do |fragment|
  assert(validate_run.include?(fragment), "validate-release-ref must include #{fragment}")
end

release_run_blocks = release_jobs.values.flat_map { |job| (job["steps"] || []).map { |step| step["run"].to_s } }.join("\n")
assert(!release_run_blocks.include?("github.event.inputs.version"), "release run scripts must not interpolate workflow inputs directly")

version_bump = release_jobs.fetch("version-bump")
assert(job_needs(version_bump).include?("validate-release-ref"), "version-bump must depend on validate-release-ref")
assert(version_bump["if"].to_s.include?("workflow_dispatch"), "version-bump must only run for manual releases")
assert(version_bump.dig("permissions", "contents") == "write", "version-bump must scope contents: write to its job")
version_bump_steps = steps_for(release_jobs, "version-bump")
["Update version in gos.sh", "Update CHANGELOG.md", "Commit and tag"].each do |name|
  step = step_named(version_bump_steps, name)
  assert(step, "version-bump must define #{name} step")
  step_env = step["env"] || {}
  assert(step_env.values.any? { |value| value.to_s.include?("needs.validate-release-ref.outputs") }, "#{name} must use validated release outputs")
end

smoke_job = release_jobs.fetch("smoke-test")
assert(job_needs(smoke_job).include?("validate-release-ref"), "smoke-test must depend on validate-release-ref")
assert(job_needs(smoke_job).include?("version-bump"), "smoke-test must depend on version-bump")
smoke_steps = steps_for(release_jobs, "smoke-test")
smoke_runs = smoke_steps.map { |step| step["run"].to_s }
smoke_checkout = smoke_steps.find { |step| step["uses"].to_s == "actions/checkout@v5" }
assert(smoke_checkout, "smoke-test must checkout the release tag")
assert(smoke_checkout.dig("with", "ref").to_s.include?("needs.validate-release-ref.outputs.tag"), "smoke-test must checkout the validated release tag")
assert(smoke_runs.any? { |run| run.include?("./gos.sh version") }, "release smoke-test must run gos version")
assert(smoke_runs.any? { |run| run.include?("./gos.sh help") }, "release smoke-test must run gos help")

release_job = release_jobs.fetch("release")
assert(job_needs(release_job).include?("validate-release-ref"), "release job must depend on validate-release-ref")
assert(job_needs(release_job).include?("version-bump"), "release job must depend on version-bump")
assert(job_needs(release_job).include?("smoke-test"), "release job must depend on smoke-test")
assert(release_job.dig("permissions", "contents") == "write", "release job must scope contents: write to release publishing")
assert(release_job.dig("permissions", "id-token") == "write", "release job must grant id-token: write for attestations")
assert(release_job.dig("permissions", "attestations") == "write", "release job must grant attestations: write")
release_steps = steps_for(release_jobs, "release")
release_uses = release_steps.map { |step| step["uses"].to_s }
assert(release_uses.include?("softprops/action-gh-release@v3"), "release workflow must use softprops/action-gh-release@v3")
assert(release_uses.include?("actions/attest@v4"), "release workflow must use actions/attest@v4")
release_checkout = release_steps.find { |step| step["uses"].to_s == "actions/checkout@v5" }
assert(release_checkout, "release job must checkout the release tag")
assert(release_checkout.dig("with", "ref").to_s.include?("needs.validate-release-ref.outputs.tag"), "release job must checkout the validated release tag")

release_files = release_steps
  .map { |step| step.dig("with", "files").to_s }
  .join("\n")
%w[gos.sh install.sh checksums.txt].each do |asset|
  assert(release_files.include?(asset), "release workflow must upload #{asset}")
end
assert(release_steps.any? { |step| step.dig("with", "subject-checksums").to_s == "checksums.txt" }, "release workflow must attest script assets from checksums.txt")
assert(release_steps.any? { |step| step.dig("with", "subject-path").to_s.include?("checksums.txt") }, "release workflow must attest checksums.txt")

update_formula = release_jobs.fetch("update-formula")
assert(job_needs(update_formula).include?("validate-release-ref"), "update-formula must depend on validate-release-ref")
assert(job_needs(update_formula).include?("release"), "update-formula must depend on release")
assert(update_formula.dig("permissions", "contents") != "write", "update-formula must not request current-repo contents: write")
update_formula_steps = steps_for(release_jobs, "update-formula")
update_formula_runs = update_formula_steps.map { |step| step["run"].to_s }.join("\n")
assert(update_formula_runs.include?('TAG:?missing release tag'), "update-formula must use the validated release tag")

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
  "bash tests/install-sh.bash",
  "bash tests/windows-extract.bash",
  "bash -n gos.sh install.sh completions/gos.bash tests/checksum.bash tests/install-transaction.bash tests/install-sh.bash tests/windows-extract.bash tests/workflows.bash",
  "./gos.sh version",
  "./gos.sh help",
  "zsh -n completions/gos.zsh",
  "fish --no-config --no-execute completions/gos.fish"
].each do |command|
  assert(smoke_runs.include?(command), "smoke job must run #{command}")
end

packaging_files = Dir.glob("packaging/**/*").select { |path| File.file?(path) }
packaging_text = packaging_files.map { |path| File.read(path) }.join("\n")
[
  "packaging/README.md",
  "packaging/chocolatey/gos.nuspec",
  "packaging/chocolatey/tools/chocolateyInstall.ps1",
  "packaging/chocolatey/tools/chocolateyUninstall.ps1",
  "packaging/chocolatey/tools/gos.cmd",
  "packaging/winget/johnny4young.gos.yaml"
].each do |path|
  assert(File.file?(path), "packaging must keep #{path}")
end
assert(!packaging_text.include?("FILL_AFTER_RELEASE"), "packaging manifests must not contain placeholder checksums")
assert(!packaging_text.include?("v1.0.0"), "packaging manifests must not point at stale v1.0.0 assets")
assert(!packaging_text.include?("<version>1.0.0</version>"), "Chocolatey manifest must not keep stale 1.0.0 version")
assert(!packaging_text.include?("PackageVersion: 1.0.0"), "Winget manifest must not keep stale 1.0.0 version")
assert(packaging_text.include?("<version>#{gos_version}</version>"), "Chocolatey manifest must match GOS_VERSION")
assert(packaging_text.include?("PackageVersion: #{gos_version}"), "Winget manifest must match GOS_VERSION")
assert(packaging_text.include?("releases/download/v#{gos_version}/gos.sh"), "Chocolatey install must use the current release asset")
assert(packaging_text.include?("-ChecksumType 'sha256'"), "Chocolatey install must verify the release asset checksum")
assert(packaging_text.include?("Install-BinFile -Name 'gos'"), "Chocolatey install must expose a gos command shim")
assert(readme.include?("Windows Package Managers"), "README must explain Windows package-manager status")
assert(!readme.include?("winget install johnny4young.gos"), "README must not advertise unpublished Winget install command")
assert(!readme.include?("choco install gos"), "README must not advertise unpublished Chocolatey install command")

puts "ok - workflow YAML and invariants"
RUBY
