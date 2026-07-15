#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

test_root="$(mktemp -d)"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

fail_shell() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

validate_help_stdout="${test_root}/validate-help.stdout"
validate_help_stderr="${test_root}/validate-help.stderr"
bash scripts/validate-local.bash --help >"$validate_help_stdout" 2>"$validate_help_stderr"
grep -Fq "Usage: validate-local.bash [--help]" "$validate_help_stdout" \
  || fail_shell "validate-local --help must print usage to stdout"
[ ! -s "$validate_help_stderr" ] \
  || fail_shell "validate-local --help must not print stderr"

validate_invalid_stdout="${test_root}/validate-invalid.stdout"
validate_invalid_stderr="${test_root}/validate-invalid.stderr"
set +e
bash scripts/validate-local.bash --bogus >"$validate_invalid_stdout" 2>"$validate_invalid_stderr"
cmd_status=$?
set -e
[ "$cmd_status" -eq 2 ] \
  || fail_shell "validate-local invalid usage must exit 2"
[ ! -s "$validate_invalid_stdout" ] \
  || fail_shell "validate-local invalid usage must not print stdout"
grep -Fq "Usage: validate-local.bash [--help]" "$validate_invalid_stderr" \
  || fail_shell "validate-local invalid usage must print usage to stderr"

# -EUTF-8 keeps file parsing locale-independent (repo files contain UTF-8).
ruby -EUTF-8 <<'RUBY'
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
canary = workflow(".github/workflows/canary.yml")
readme = file_text("README.md")
releasing = file_text("RELEASING.md")
contributing = file_text("CONTRIBUTING.md")
pr_template = file_text(".github/PULL_REQUEST_TEMPLATE.md")
validate_local = file_text("scripts/validate-local.bash")
security = file_text("SECURITY.md")
bash_completion = file_text("completions/gos.bash")
zsh_completion = file_text("completions/gos.zsh")
fish_completion_file = file_text("completions/gos.fish")
gos_version = file_text("gos.sh")[/^GOS_VERSION="([^"]+)"$/, 1]
assert(gos_version && !gos_version.empty?, "gos.sh must define GOS_VERSION")
public_commands = `bash gos.sh __commands`.lines.map(&:strip).reject(&:empty?)
assert($?.success?, "gos __commands must succeed for workflow invariants")
assert(!public_commands.empty?, "gos __commands must list public commands")
command_surfaces_sync_output = `bash scripts/sync-command-surfaces.bash --check 2>&1`
assert($?.success?, "Command surfaces must match gos command manifest: #{command_surfaces_sync_output}")
assert(!releasing.empty?, "repository must include RELEASING.md")
assert(!contributing.empty?, "repository must include CONTRIBUTING.md")
assert(!pr_template.empty?, "repository must include PULL_REQUEST_TEMPLATE.md")
assert(!validate_local.empty?, "repository must include scripts/validate-local.bash")
assert(!security.empty?, "repository must include SECURITY.md")

release_on = workflow_on(release)
assert(release_on.dig("workflow_dispatch", "inputs", "version"), "release workflow must keep workflow_dispatch version input")
assert(release.dig("permissions", "contents") == "read", "release workflow must use read-only top-level contents permission")
assert(release.dig("defaults", "run", "shell") == "bash", "release workflow must default to bash shell")

release_jobs = release.fetch("jobs") { fail!("release workflow must define jobs") }
%w[validate-release-ref release-preflight version-bump smoke-test release update-formula].each do |job|
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
  "Manual releases must be run from main",
  "push)",
  "version=%s",
  "tag=%s",
  "GITHUB_OUTPUT"
].each do |fragment|
  assert(validate_run.include?(fragment), "validate-release-ref must include #{fragment}")
end

release_run_blocks = release_jobs.values.flat_map { |job| (job["steps"] || []).map { |step| step["run"].to_s } }.join("\n")
assert(!release_run_blocks.include?("github.event.inputs.version"), "release run scripts must not interpolate workflow inputs directly")

release_preflight = release_jobs.fetch("release-preflight")
assert(job_needs(release_preflight).include?("validate-release-ref"), "release-preflight must depend on validate-release-ref")
assert(release_preflight["if"].to_s.include?("workflow_dispatch"), "release-preflight must only run for manual releases")
assert(release_preflight.dig("permissions", "contents") != "write", "release-preflight must not request contents: write")
release_preflight_steps = steps_for(release_jobs, "release-preflight")
release_preflight_checkout = release_preflight_steps.find { |step| step["uses"].to_s.start_with?("actions/checkout@") }
assert(release_preflight_checkout, "release-preflight must checkout the repository")
assert(release_preflight_checkout.dig("with", "fetch-depth") == 0, "release-preflight must fetch tags before checking tag uniqueness")
release_preflight_step = step_named(release_preflight_steps, "Validate manual release readiness")
assert(release_preflight_step, "release-preflight must validate manual release readiness")
release_preflight_env = release_preflight_step["env"] || {}
assert(release_preflight_env.values.any? { |value| value.to_s.include?("needs.validate-release-ref.outputs") }, "release-preflight must use validated release outputs")
release_preflight_run = release_preflight_step["run"].to_s
assert(release_preflight_run.include?("refs/tags/${TAG}"), "release-preflight must fail before reusing an existing tag")
assert(release_preflight_run.include?("Release tag %s already exists"), "release-preflight must explain existing tag failures")
assert(release_preflight_run.include?('scripts/update-changelog.bash --check "$VERSION"'), "release-preflight must validate changelog notes without mutating files")

version_bump = release_jobs.fetch("version-bump")
assert(job_needs(version_bump).include?("validate-release-ref"), "version-bump must depend on validate-release-ref")
assert(job_needs(version_bump).include?("release-preflight"), "version-bump must wait for release-preflight")
assert(version_bump["if"].to_s.include?("workflow_dispatch"), "version-bump must only run for manual releases")
assert(version_bump.dig("permissions", "contents") == "write", "version-bump must scope contents: write to its job")
version_bump_steps = steps_for(release_jobs, "version-bump")
version_bump_checkout = version_bump_steps.find { |step| step["uses"].to_s.start_with?("actions/checkout@") }
assert(version_bump_checkout, "version-bump must checkout the repository")
assert(version_bump_checkout.dig("with", "fetch-depth") == 0, "version-bump must fetch tags for changelog compare links")
["Update version in gos.sh", "Update CHANGELOG.md", "Commit and tag"].each do |name|
  step = step_named(version_bump_steps, name)
  assert(step, "version-bump must define #{name} step")
  step_env = step["env"] || {}
  assert(step_env.values.any? { |value| value.to_s.include?("needs.validate-release-ref.outputs") }, "#{name} must use validated release outputs")
end

smoke_job = release_jobs.fetch("smoke-test")
assert(job_needs(smoke_job).include?("validate-release-ref"), "smoke-test must depend on validate-release-ref")
assert(job_needs(smoke_job).include?("release-preflight"), "smoke-test must depend on release-preflight")
assert(job_needs(smoke_job).include?("version-bump"), "smoke-test must depend on version-bump")
assert(smoke_job["if"].to_s.include?("needs.release-preflight.result"), "smoke-test must respect release-preflight result")
smoke_steps = steps_for(release_jobs, "smoke-test")
smoke_runs = smoke_steps.map { |step| step["run"].to_s }
smoke_checkout = smoke_steps.find { |step| step["uses"].to_s.start_with?("actions/checkout@") }
assert(smoke_checkout, "smoke-test must checkout the release tag")
assert(smoke_checkout.dig("with", "ref").to_s.include?("needs.validate-release-ref.outputs.tag"), "smoke-test must checkout the validated release tag")
assert(smoke_runs.any? { |run| run.include?("./gos.sh version") }, "release smoke-test must run gos version")
assert(smoke_runs.any? { |run| run.include?("./gos.sh help") }, "release smoke-test must run gos help")

release_job = release_jobs.fetch("release")
assert(job_needs(release_job).include?("validate-release-ref"), "release job must depend on validate-release-ref")
assert(job_needs(release_job).include?("release-preflight"), "release job must depend on release-preflight")
assert(job_needs(release_job).include?("version-bump"), "release job must depend on version-bump")
assert(job_needs(release_job).include?("smoke-test"), "release job must depend on smoke-test")
assert(release_job["if"].to_s.include?("needs.release-preflight.result"), "release job must respect release-preflight result")
assert(release_job.dig("permissions", "contents") == "write", "release job must scope contents: write to release publishing")
assert(release_job.dig("permissions", "id-token") == "write", "release job must grant id-token: write for attestations")
assert(release_job.dig("permissions", "attestations") == "write", "release job must grant attestations: write")
release_steps = steps_for(release_jobs, "release")
release_uses = release_steps.map { |step| step["uses"].to_s }
assert(release_uses.any? { |used| used.start_with?("softprops/action-gh-release@") }, "release workflow must use softprops/action-gh-release")
assert(release_uses.any? { |used| used.start_with?("actions/attest@") }, "release workflow must use actions/attest")
release_checkout = release_steps.find { |step| step["uses"].to_s.start_with?("actions/checkout@") }
assert(release_checkout, "release job must checkout the release tag")
assert(release_checkout.dig("with", "ref").to_s.include?("needs.validate-release-ref.outputs.tag"), "release job must checkout the validated release tag")

release_files = release_steps
  .map { |step| step.dig("with", "files").to_s }
  .join("\n")
%w[gos.sh install.sh install.ps1 gos-windows.zip checksums.txt].each do |asset|
  assert(release_files.include?(asset), "release workflow must upload #{asset}")
end
assert(release_steps.any? { |step| step.dig("with", "subject-checksums").to_s == "checksums.txt" }, "release workflow must attest script assets from checksums.txt")
assert(release_steps.any? { |step| step.dig("with", "subject-path").to_s.include?("checksums.txt") }, "release workflow must attest checksums.txt")
release_runs = release_steps.map { |step| step["run"].to_s }.join("\n")
assert(release_runs.include?("gos-windows.zip"), "release workflow must build the Windows package asset")
assert(release_runs.include?("scripts/build-windows-package.bash"), "release workflow must use the Windows package builder")
assert(release_runs.include?("$GosExpectedZipSha256"), "release workflow must patch install.ps1 with the Windows package checksum")
assert(release_runs.include?("sha256sum install.ps1"), "release workflow must checksum install.ps1")
assert(release_runs.include?("sha256sum gos-windows.zip"), "release workflow must checksum gos-windows.zip")
assert(step_named(release_steps, "Validate package metadata"), "release workflow must validate package metadata before publishing")
assert(release_runs.include?("PackageVersion: ${VERSION}"), "release workflow must validate Winget version metadata")
assert(release_runs.include?("InstallerSha256: ${WINDOWS_SHA}"), "release workflow must validate Winget checksum metadata")

version_bump_runs = version_bump_steps.map { |step| step["run"].to_s }.join("\n")
assert(version_bump_runs.include?("scripts/update-packaging.bash"), "version-bump must update package metadata")
assert(version_bump_runs.include?("scripts/update-changelog.bash"), "version-bump must use the changelog release helper")
assert(!version_bump_runs.include?("git log"), "version-bump must not generate release notes from commit subjects")
assert(!version_bump_runs.include?("head -5 CHANGELOG.md"), "version-bump must not insert release notes before Unreleased")
assert(version_bump_runs.include?("packaging/chocolatey/gos.nuspec"), "version-bump commit must include Chocolatey metadata")
assert(version_bump_runs.include?("packaging/winget/johnny4young.gos.yaml"), "version-bump commit must include Winget metadata")

update_formula = release_jobs.fetch("update-formula")
assert(job_needs(update_formula).include?("validate-release-ref"), "update-formula must depend on validate-release-ref")
assert(job_needs(update_formula).include?("release"), "update-formula must depend on release")
assert(update_formula.dig("permissions", "contents") != "write", "update-formula must not request current-repo contents: write")
update_formula_steps = steps_for(release_jobs, "update-formula")
update_formula_checkout = update_formula_steps.find { |step| step["uses"].to_s.start_with?("actions/checkout@") }
assert(update_formula_checkout, "update-formula must checkout the released gos source for the bump script and template")
assert(update_formula_checkout.dig("with", "ref").to_s.include?("needs.validate-release-ref.outputs.tag"), "update-formula must checkout the validated release tag")
update_formula_runs = update_formula_steps.map { |step| step["run"].to_s }.join("\n")
assert(update_formula_runs.include?('TAG:?missing release tag'), "update-formula must use the validated release tag")
assert(update_formula_runs.include?("scripts/update-homebrew-tap.sh"), "update-formula must use the vendored central-tap bump script")
assert(update_formula_runs.include?("--kind formula"), "update-formula must publish a formula to the tap")
assert(update_formula_runs.include?("--template packaging/Formula/gos.rb"), "update-formula must regenerate the formula from the in-repo template")
update_formula_env = update_formula_steps.flat_map { |step| (step["env"] || {}).to_a }
assert(update_formula_env.any? { |key, value| key == "TAP_DEPLOY_KEY" && value.to_s.include?("secrets.TAP_DEPLOY_KEY") }, "update-formula must push to the central tap over the TAP_DEPLOY_KEY deploy key")
assert(!update_formula_runs.include?("HOMEBREW_TAP_TOKEN"), "update-formula must not use the deprecated homebrew-gos token")

canary_on = workflow_on(canary)
assert(canary_on.key?("schedule"), "canary workflow must run on a schedule")
assert(canary_on.key?("workflow_dispatch"), "canary workflow must support manual runs")
assert(canary.dig("permissions", "contents") == "read", "canary workflow must use read-only contents permission")
canary_matrix = canary.dig("jobs", "live-feed", "strategy", "matrix", "os") || []
%w[ubuntu-latest macos-latest windows-latest].each do |os|
  assert(canary_matrix.include?(os), "canary matrix must include #{os}")
end
canary_runs = canary.dig("jobs", "live-feed", "steps").map { |step| step["run"].to_s }.join("\n")
assert(canary_runs.include?("./gos.sh check"), "canary must run gos check against the live feed")
assert(canary_runs.include?("./gos.sh rollback"), "canary must exercise rollback against a real install")

ci_on = workflow_on(ci)
assert(ci_on.key?("pull_request"), "CI must run on pull_request")
assert(ci_on.dig("push", "branches")&.include?("main"), "CI must run on pushes to main")
assert(ci.dig("permissions", "contents") == "read", "CI must use read-only contents permission")
assert(ci.dig("defaults", "run", "shell") == "bash", "CI must default to bash shell")

ci_jobs = ci.fetch("jobs") { fail!("CI must define jobs") }
%w[shellcheck shfmt smoke workflow-validation].each do |job|
  assert(ci_jobs.key?(job), "CI must define #{job} job")
end

shellcheck_runs = ci_jobs.dig("shellcheck", "steps").map { |step| step["run"].to_s }.join("\n")
assert(shellcheck_runs.include?("shellcheck gos.sh install.sh completions/gos.bash scripts/*.bash scripts/*.sh tests/*.bash"), "ShellCheck job must cover scripts and tests")

shfmt_job = ci_jobs.fetch("shfmt") { fail!("CI must define shfmt job") }
assert(shfmt_job["runs-on"] == "ubuntu-latest", "shfmt job must run on ubuntu")
assert(shfmt_job.dig("env", "SHFMT_VERSION") == "v3.13.1", "shfmt job must pin mvdan/sh release")
shfmt_runs = shfmt_job.fetch("steps").map { |step| step["run"].to_s }.join("\n")
assert(shfmt_runs.include?("mvdan/sh/releases/download/${SHFMT_VERSION}/shfmt_${SHFMT_VERSION}_linux_amd64"), "shfmt job must install pinned release binary")
assert(shfmt_runs.include?("shfmt -d -i 2 -ci -bn ."), "shfmt job must enforce repo formatting")

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

command_surface_sync = step_named(smoke_steps, "Command surface sync")
assert(command_surface_sync, "smoke job must check generated command surfaces")
assert(command_surface_sync["run"].to_s.include?("bash scripts/sync-command-surfaces.bash --check"), "command surface sync must use the orchestrator")

[
  "bash tests/changelog.bash",
  "bash tests/checksum.bash",
  "bash tests/completions.bash",
  "bash tests/detection.bash",
  "bash tests/features.bash",
  "bash tests/homebrew-tap.bash",
  "bash tests/install-transaction.bash",
  "bash tests/install-sh.bash",
  "bash tests/install-ps1.bash",
  "bash tests/packaging.bash",
  "bash tests/windows-extract.bash",
  "bash scripts/sync-command-surfaces.bash --check",
  "bash -n gos.sh install.sh completions/gos.bash scripts/build-windows-package.bash scripts/sync-bash-command-completions.bash scripts/sync-command-surfaces.bash scripts/sync-embedded-completions.bash scripts/sync-fish-command-completions.bash scripts/sync-readme-usage.bash scripts/sync-zsh-command-completions.bash scripts/update-changelog.bash scripts/update-homebrew-tap.sh scripts/update-packaging.bash scripts/validate-local.bash tests/changelog.bash tests/checksum.bash tests/completions.bash tests/detection.bash tests/features.bash tests/homebrew-tap.bash tests/install-transaction.bash tests/install-sh.bash tests/install-ps1.bash tests/lib.bash tests/packaging.bash tests/windows-extract.bash tests/workflows.bash",
  "./gos.sh version",
  "./gos.sh help",
  "zsh -n completions/gos.zsh",
  "fish --no-config --no-execute completions/gos.fish"
].each do |command|
  assert(smoke_runs.include?(command), "smoke job must run #{command}")
end
assert(smoke_runs.include?("packaging/windows/uninstall.ps1"), "smoke job must parse the PowerShell uninstaller")
assert(smoke_runs.include?("tests/install-ps1.ps1"), "smoke job must parse the PowerShell installer test")
assert(smoke_runs.include?("powershell -NoProfile -ExecutionPolicy Bypass -File tests/install-ps1.ps1"), "smoke job must run the functional PowerShell installer test")

packaging_files = Dir.glob("packaging/**/*").select { |path| File.file?(path) }
packaging_text = packaging_files.map { |path| File.read(path) }.join("\n")
[
  "packaging/README.md",
  "packaging/Formula/gos.rb",
  "install.ps1",
  "scripts/build-windows-package.bash",
  "scripts/sync-bash-command-completions.bash",
  "scripts/sync-command-surfaces.bash",
  "scripts/sync-fish-command-completions.bash",
  "scripts/sync-zsh-command-completions.bash",
  "scripts/update-changelog.bash",
  "scripts/update-homebrew-tap.sh",
  "scripts/update-packaging.bash",
  "scripts/validate-local.bash",
  "packaging/windows/gos.cmd",
  "packaging/windows/uninstall.ps1",
  "tests/install-ps1.ps1",
  "tests/changelog.bash",
  "tests/features.bash",
  "tests/packaging.bash",
  "packaging/chocolatey/gos.nuspec",
  "packaging/chocolatey/tools/chocolateyInstall.ps1",
  "packaging/chocolatey/tools/chocolateyUninstall.ps1",
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
assert(packaging_text.include?("releases/download/v#{gos_version}/gos-windows.zip"), "package metadata must use the current Windows release asset")
# The Homebrew formula template legitimately pins a source tarball, so scope the
# "no source archives" rule to the Windows package-manager manifests it targets.
winget_manifest = file_text("packaging/winget/johnny4young.gos.yaml")
choco_install = file_text("packaging/chocolatey/tools/chocolateyInstall.ps1")
assert(!winget_manifest.include?("archive/refs/tags") && !choco_install.include?("archive/refs/tags"), "Windows package manifests must not point at source archives")
assert(packaging_text.include?("Get-ChocolateyUnzip"), "Chocolatey install must unpack the Windows release asset")
assert(packaging_text.include?("-ChecksumType 'sha256'"), "Chocolatey install must verify the release asset checksum")
assert(packaging_text.include?("Install-BinFile -Name 'gos'"), "Chocolatey install must expose a gos command shim")
assert(readme.include?("PowerShell"), "README must explain the PowerShell Windows install path")
assert(readme.include?("It does not install Go"), "README must say the PowerShell installer only installs gos")
assert(readme.include?("To update `gos`, run the same PowerShell installer again"), "README must document how to update gos on Windows")
assert(readme.include?("Windows Package Managers"), "README must explain Windows package-manager status")
assert(readme.include?("SECURITY.md"), "README must link to SECURITY.md")
assert(!readme.include?("winget install johnny4young.gos"), "README must not advertise unpublished Winget install command")
assert(!readme.include?("choco install gos"), "README must not advertise unpublished Chocolatey install command")

public_commands.each do |command|
  assert(readme.include?("gos #{command}"), "README must document gos #{command}")
  assert(bash_completion.include?(command), "Bash completion must include #{command}")
  assert(zsh_completion.include?(command), "Zsh completion must include #{command}")
  assert(fish_completion_file.include?(command), "Fish completion must include #{command}")
end
assert(readme.include?("gos completions bash"), "README must document embedded completion setup")
assert(readme.include?("Homebrew installs completion files automatically"), "README must not claim curl bash installs completions automatically")
assert(!readme.include?("curl | bash` or Homebrew, completions may already be set up"), "README must not claim curl bash installs completions automatically")
assert(!readme.include?("go1.24.1\ngo1.24.0"), "README gos list example must not show newest-first ordering")
assert(readme.include?("--json"), "README must document --json")
assert(bash_completion.include?("--json"), "Bash completion must include --json")
assert(zsh_completion.include?("--json"), "Zsh completion must include --json")
assert(fish_completion_file.include?("-l json"), "Fish completion must include --json")
assert(readme.include?("gos status --json"), "README must document status JSON")
assert(readme.include?("GOS_FEED_TTL"), "README must document feed cache TTL")
assert(readme.include?("gos doctor --fix"), "README must document doctor --fix")
assert(readme.include?("gos env --auto"), "README must document env --auto")
assert(readme.include?(".gos-lock"), "README must mention the concurrent-operation guard")
assert(bash_completion.include?("__versions --remote-cached"), "Bash completion must use cached dynamic versions")
assert(zsh_completion.include?("__versions --remote-cached"), "Zsh completion must use cached dynamic versions")
assert(fish_completion_file.include?("__versions --remote-cached"), "Fish completion must use cached dynamic versions")
assert(bash_completion.include?("install | run"), "Bash completion must complete install/run versions")
assert(zsh_completion.include?("install | run"), "Zsh completion must complete install/run versions")
assert(fish_completion_file.include?("__fish_seen_subcommand_from install run"), "Fish completion must complete install/run versions")
assert(bash_completion.include?("--fix"), "Bash completion must include doctor --fix")
assert(zsh_completion.include?("--fix"), "Zsh completion must include doctor --fix")
assert(fish_completion_file.include?("-l fix"), "Fish completion must include doctor --fix")
assert(bash_completion.include?("--auto"), "Bash completion must include env --auto")
assert(zsh_completion.include?("--auto"), "Zsh completion must include env --auto")
assert(fish_completion_file.include?("-l auto"), "Fish completion must include env --auto")

assert(contributing.include?("_gos_command_manifest"), "CONTRIBUTING must point command changes at the manifest")
assert(contributing.include?("scripts/sync-command-surfaces.bash --write"), "CONTRIBUTING must document command surface sync writes")
assert(contributing.include?("scripts/sync-command-surfaces.bash --check"), "CONTRIBUTING must document command surface sync checks")

assert(contributing.include?("scripts/validate-local.bash"), "CONTRIBUTING validation must use the local validation orchestrator")
assert(contributing.include?("optional") && contributing.include?("ShellCheck/shfmt/zsh/Fish/PowerShell checks"), "CONTRIBUTING must explain optional local validation tools")

[
  "pwsh",
  "powershell",
  "install.ps1",
  "packaging/windows/uninstall.ps1",
  "tests/install-ps1.ps1",
  "run_quiet ./gos.sh help"
].each do |fragment|
  assert(validate_local.include?(fragment), "validate-local must include #{fragment}")
end

[
  "scripts/validate-local.bash",
  "shellcheck gos.sh install.sh completions/gos.bash scripts/*.bash scripts/*.sh tests/*.bash",
  "scripts/sync-command-surfaces.bash --check",
  "bash tests/completions.bash",
  "bash tests/workflows.bash"
].each do |command|
  assert(pr_template.include?(command), "PR template validation must include #{command}")
end

[
  "workflow_dispatch",
  "TAP_DEPLOY_KEY",
  "CHANGELOG.md",
  "## [Unreleased]",
  "README.md",
  "gos.sh",
  "install.sh",
  "install.ps1",
  "gos-windows.zip",
  "checksums.txt",
  "Homebrew",
  "PowerShell",
  "Chocolatey",
  "Winget",
  "bash tests/packaging.bash",
  "bash tests/completions.bash",
  "bash tests/homebrew-tap.bash",
  "bash tests/changelog.bash",
  "bash tests/workflows.bash",
  "scripts/validate-local.bash",
  "scripts/sync-command-surfaces.bash --check",
  "shfmt -d -i 2 -ci -bn .",
  "git diff --check",
  "scripts/update-changelog.bash",
  "scripts/update-packaging.bash"
].each do |fragment|
  assert(releasing.include?(fragment), "RELEASING.md must mention #{fragment}")
end
assert(releasing.include?("fallback git commit subjects"), "RELEASING.md must explain fallback changelog generation")
assert(releasing.include?("tests/changelog.bash` fails a post-tag branch"), "RELEASING.md must explain the curated Unreleased guard")
assert(!releasing.include?("Curated bullets under `Unreleased` are optional"), "RELEASING.md must not describe curated release notes as optional")
assert(releasing.include?("SECURITY.md"), "RELEASING.md must include security-release checks")
assert(releasing.include?("no public Chocolatey or Winget install commands"), "RELEASING.md must keep package-manager commands gated")
assert(releasing.include?("`[Unreleased]` compare link"), "RELEASING.md must include changelog compare-link checks")

[
  "Supported Versions",
  "Reporting a Vulnerability",
  "GitHub Security Advisories",
  "Do not open public issues",
  "Security Scope",
  "Trust Model",
  "latest published `gos` version",
  "go.dev/dl",
  "include=all",
  "GOS_REQUIRE_CHECKSUM=1",
  "transactional",
  "install.sh",
  "install.ps1",
  "gos-windows.zip",
  "checksums.txt",
  "artifact attestations",
  "Raw `main` installer URLs"
].each do |fragment|
  assert(security.include?(fragment), "SECURITY.md must mention #{fragment}")
end

puts "ok - workflow YAML and invariants"
RUBY
