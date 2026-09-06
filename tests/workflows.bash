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

assert_validate_help_stdout() {
  local label="$1"
  shift
  local stdout_file="${test_root}/${label}.stdout"
  local stderr_file="${test_root}/${label}.stderr"

  bash scripts/validate-local.bash "$@" >"$stdout_file" 2>"$stderr_file"
  grep -Fq "Usage: validate-local.bash [--required-only|--strict|--help]" "$stdout_file" \
    || fail_shell "validate-local ${label} must print usage to stdout"
  grep -Fq "workflow YAML syntax" "$stdout_file" \
    || fail_shell "validate-local ${label} must list workflow YAML checks"
  grep -Fq "Required external tools:" "$stdout_file" \
    || fail_shell "validate-local ${label} must list required external tools"
  grep -Fq -- "--required-only" "$stdout_file" \
    || fail_shell "validate-local ${label} must list required-only mode"
  grep -Fq "ruby (workflow YAML syntax)" "$stdout_file" \
    || fail_shell "validate-local ${label} must list Ruby as required"
  grep -Fq "CLI smoke checks" "$stdout_file" \
    || fail_shell "validate-local ${label} must list CLI smoke checks"
  grep -Fq "git whitespace checks" "$stdout_file" \
    || fail_shell "validate-local ${label} must list whitespace checks"
  [ ! -s "$stderr_file" ] \
    || fail_shell "validate-local ${label} must not print stderr"
}

assert_validate_invalid_usage() {
  local label="$1"
  shift
  local stdout_file="${test_root}/${label}.stdout"
  local stderr_file="${test_root}/${label}.stderr"
  local cmd_status

  set +e
  bash scripts/validate-local.bash "$@" >"$stdout_file" 2>"$stderr_file"
  cmd_status=$?
  set -e
  [ "$cmd_status" -eq 2 ] \
    || fail_shell "validate-local ${label} must exit 2"
  [ ! -s "$stdout_file" ] \
    || fail_shell "validate-local ${label} must not print stdout"
  grep -Fq "Usage: validate-local.bash [--required-only|--strict|--help]" "$stderr_file" \
    || fail_shell "validate-local ${label} must print usage to stderr"
}

assert_validate_help_stdout "help-long" --help
assert_validate_help_stdout "help-short" -h
assert_validate_invalid_usage "invalid-option" --bogus
assert_validate_invalid_usage "extra-argument" --help extra
assert_validate_invalid_usage "required-only-extra-argument" --required-only extra

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

def script_array(script, name)
  body = script[/^#{Regexp.escape(name)}=\(\n(.*?)^\)/m, 1]
  fail!("scripts/validate-local.bash must define #{name}") unless body

  body.lines.map { |line| line.sub(/#.*/, "").strip }.reject(&:empty?)
end

workflow_paths = Dir[".github/workflows/*.{yml,yaml}"].sort
assert(!workflow_paths.empty?, "repository must include GitHub Actions workflows")
workflows = {}
workflow_paths.each { |path| workflows[path] = workflow(path) }

release = workflows.fetch(".github/workflows/release.yml")
ci = workflows.fetch(".github/workflows/ci.yml")
canary = workflows.fetch(".github/workflows/canary.yml")
scorecard = workflows.fetch(".github/workflows/scorecard.yml")
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
tracked_files = `git ls-files`.lines.map(&:strip)
assert($?.success?, "git ls-files must succeed for repository inventory checks")
assert(!tracked_files.empty?, "repository inventory must not be empty")

# A mutable tag can silently change the code executed with repository tokens.
# Cover every current and future workflow, including reusable workflows invoked
# at the job level, so the supply-chain hardening cannot drift after this PR.
workflows.each do |path, config|
  jobs = config.fetch("jobs") { fail!("#{path} must define jobs") }
  references = jobs.values.flat_map do |job|
    [job["uses"], *(job["steps"] || []).map { |step| step["uses"] }]
  end.compact
  references.reject { |used| used.start_with?("./") }.each do |used|
    assert(used.match?(/\A[^@\s]+@[0-9a-f]{40}\z/), "#{path} must pin #{used} to a full commit SHA")
  end
end

validate_powershell_files = script_array(validate_local, "powershell_files")

tracked_shell_files = tracked_files.select { |path| path.end_with?(".bash", ".sh") }.sort
assert(validate_local.include?("git ls-files -z '*.sh' '*.bash'"), "validate-local must derive its Bash syntax file list from git ls-files like CI")
assert(tracked_shell_files.include?("scripts/run-tests.bash"), "the suite runner must be tracked")

# Suites are discovered by scripts/run-tests.bash from git, so the only
# registration is the file itself; assert the runner sees every tracked suite
# and that the per-OS rules match what CI used to hard-code.
tracked_test_scripts = tracked_files.select { |path| path.start_with?("tests/") && path.end_with?(".bash") && !File.basename(path).start_with?("lib") }.sort
assert(validate_local.include?("scripts/run-tests.bash"), "validate-local must run the suites through scripts/run-tests.bash")
linux_listing = `bash scripts/run-tests.bash --list --os linux`
assert($?.success?, "Linux suite discovery must succeed")
assert(linux_listing.lines.include?("tests/runner.bash\n"), "runner regressions must run on Linux, not inherit fixture metadata")
listed_suites = linux_listing.lines.map { |line| line.split("\t").first.strip }.sort
assert($?.success?, "scripts/run-tests.bash --list must succeed")
assert(listed_suites == tracked_test_scripts, "run-tests must discover every tracked suite: #{listed_suites.inspect} vs #{tracked_test_scripts.inspect}")
windows_skips = `bash scripts/run-tests.bash --list --os windows`.lines.select { |line| line.include?("skipped") }.map { |line| line.split("\t").first.strip }
assert($?.success?, "Windows suite discovery must succeed")
%w[tests/workflows.bash tests/runner.bash].each do |suite|
  assert(!windows_skips.include?(suite), "#{suite} must run on Windows")
end
%w[tests/side-by-side.bash tests/doctor-status.bash tests/packaging.bash tests/homebrew-tap.bash].each do |suite|
  next unless tracked_test_scripts.include?(suite)
  assert(windows_skips.include?(suite), "#{suite} must declare it does not run on Windows")
end
macos_skips = `bash scripts/run-tests.bash --list --os macos`.lines.select { |line| line.include?("skipped") }.map { |line| line.split("\t").first.strip }
assert($?.success?, "macOS suite discovery must succeed")
%w[tests/packaging.bash tests/homebrew-tap.bash].each do |suite|
  assert(macos_skips.include?(suite), "#{suite} must declare only-os=linux")
end

tracked_powershell_files = tracked_files.select { |path| path.end_with?(".ps1") }.sort
assert(validate_powershell_files.sort == tracked_powershell_files, "validate-local powershell_files must cover every tracked PowerShell script")

scorecard_on = workflow_on(scorecard)
assert(scorecard_on.keys.map(&:to_s).sort == %w[push schedule], "Scorecard must run only on its supported push and schedule events")
assert(scorecard_on.dig("push", "branches") == ["main"], "Scorecard push runs must target only main")
assert(scorecard_on["schedule"].is_a?(Array) && !scorecard_on["schedule"].empty?, "Scorecard must keep a scheduled run")
assert(scorecard["permissions"] == "read-all", "Scorecard must default to read-only workflow permissions")

scorecard_jobs = scorecard.fetch("jobs") { fail!("Scorecard workflow must define jobs") }
scorecard_analysis = scorecard_jobs.fetch("analysis") { fail!("Scorecard workflow must define analysis job") }
assert(scorecard_analysis["runs-on"] == "ubuntu-latest", "Scorecard analysis must use a supported Ubuntu runner")
assert(scorecard_analysis["permissions"] == {
  "contents" => "read",
  "security-events" => "write",
  "id-token" => "write"
}, "Scorecard analysis must keep its exact least-privilege permissions")
scorecard_steps = steps_for(scorecard_jobs, "analysis")
scorecard_checkout = step_named(scorecard_steps, "Checkout code")
assert(scorecard_checkout&.dig("with", "persist-credentials") == false, "Scorecard checkout must not persist credentials")
scorecard_run = step_named(scorecard_steps, "Run analysis")
assert(scorecard_run&.dig("with", "results_file") == "results.sarif", "Scorecard must write results.sarif")
assert(scorecard_run&.dig("with", "results_format") == "sarif", "Scorecard must emit SARIF")
assert(scorecard_run&.dig("with", "publish_results") == true, "Scorecard must publish results for the public badge")
scorecard_artifact = step_named(scorecard_steps, "Upload artifact")
assert(scorecard_artifact&.dig("with", "path") == "results.sarif", "Scorecard artifact must upload results.sarif")
scorecard_upload = step_named(scorecard_steps, "Upload to code scanning")
assert(scorecard_upload&.dig("with", "sarif_file") == "results.sarif", "Scorecard code scanning upload must use results.sarif")

release_on = workflow_on(release)
assert(release_on.dig("workflow_dispatch", "inputs", "version"), "release workflow must keep workflow_dispatch version input")
assert(release.dig("permissions", "contents") == "read", "release workflow must use read-only top-level contents permission")
assert(release.dig("defaults", "run", "shell") == "bash", "release workflow must default to bash shell")

release_jobs = release.fetch("jobs") { fail!("release workflow must define jobs") }
%w[validate-release-ref release-preflight version-bump smoke-test release update-formula update-aur].each do |job|
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
version_update_run = step_named(version_bump_steps, "Update version in gos.sh")["run"].to_s
assert(version_update_run.include?("source.scan(pattern).length"), "version-bump must count GOS_VERSION assignments before rewriting gos.sh")
assert(version_update_run.include?("exactly one GOS_VERSION assignment"), "version-bump must reject missing or duplicate GOS_VERSION assignments")
commit_and_tag_run = step_named(version_bump_steps, "Commit and tag")["run"].to_s
assert(commit_and_tag_run.include?('grep -Fxc "GOS_VERSION=\"${VERSION}\""'), "version-bump must verify exactly one stamped GOS_VERSION before commit")

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
tap_key_guard = update_formula_steps.find { |step| step["name"].to_s.include?("Require the tap deploy key") }
assert(tap_key_guard, "update-formula must fail on the canonical repository when TAP_DEPLOY_KEY is missing")
assert(tap_key_guard["if"].to_s.include?("github.repository == 'johnny4young/gos'"), "the tap deploy key guard must apply only to the canonical repository")

update_aur = release_jobs.fetch("update-aur")
assert(job_needs(update_aur).include?("release"), "update-aur must run after the release exists (its digest covers the tag tarball)")
assert(update_aur["if"].to_s.include?("is_prerelease != 'true'"), "update-aur must skip pre-releases")
assert(update_aur.dig("permissions", "contents") == "write", "update-aur commits the bumped PKGBUILD to main and needs contents: write")
# Tag-push runs skip the manual-only ancestors. A status function prevents
# that expected skip from silently suppressing successful-release updates.
%w[update-formula update-aur].each do |job_name|
  condition = release_jobs.fetch(job_name).fetch("if").to_s
  assert(condition.include?("!cancelled()"), "#{job_name} must override implicit success and honor cancellation")
  ["needs.validate-release-ref.result == 'success'", "needs.release.result == 'success'", "is_prerelease != 'true'"].each do |fragment|
    assert(condition.include?(fragment), "#{job_name} must require a validated successful stable release: #{fragment}")
  end
end
update_aur_runs = steps_for(release_jobs, "update-aur").map { |step| step["run"].to_s }.join("\n")
assert(update_aur_runs.include?("scripts/update-aur.bash"), "update-aur must use scripts/update-aur.bash")
assert(update_aur_runs.include?("bash tests/packaging.bash"), "update-aur must verify the bumped files before committing")
assert(update_aur_runs.include?("git push origin HEAD:main"), "update-aur must push the bump to main")
assert(update_formula_runs.include?("--kind formula"), "update-formula must publish a formula to the tap")
assert(update_formula_runs.include?("--template packaging/Formula/gos.rb"), "update-formula must regenerate the formula from the in-repo template")
update_formula_env = update_formula_steps.flat_map { |step| (step["env"] || {}).to_a }
assert(update_formula_env.any? { |key, value| key == "TAP_DEPLOY_KEY" && value.to_s.include?("secrets.TAP_DEPLOY_KEY") }, "update-formula must push to the central tap over the TAP_DEPLOY_KEY deploy key")
assert(!update_formula_runs.include?("HOMEBREW_TAP_TOKEN"), "update-formula must not use the deprecated homebrew-gos token")

# A job without a timeout runs to the 6-hour default: one hung macOS job bills
# thousands of minutes and a hung version-bump holds the release concurrency
# group forever.
[["ci", ci], ["release", release], ["canary", canary], ["scorecard", scorecard]].each do |name, workflow|
  workflow.fetch("jobs").each do |job_name, job|
    timeout = job["timeout-minutes"]
    assert(timeout.is_a?(Integer) && timeout.between?(1, 60), "#{name} job #{job_name} must set timeout-minutes between 1 and 60")
  end
end
assert(release.dig("jobs", "smoke-test", "strategy", "fail-fast") == false, "release smoke-test matrix must not cancel the other OSes on one failure")

canary_on = workflow_on(canary)
assert(canary_on.key?("schedule"), "canary workflow must run on a schedule")
assert(canary_on.key?("workflow_dispatch"), "canary workflow must support manual runs")
assert(canary.dig("permissions", "contents") == "read", "canary workflow must use read-only contents permission")
assert(canary.dig("concurrency", "group") == "canary-live-feed", "canary workflow must serialize its list-then-create issue upsert")
assert(canary.dig("concurrency", "cancel-in-progress") == false, "canary workflow must not cancel a live run when another run is dispatched")
canary_matrix = canary.dig("jobs", "live-feed", "strategy", "matrix", "os") || []
%w[ubuntu-latest macos-latest windows-latest].each do |os|
  assert(canary_matrix.include?(os), "canary matrix must include #{os}")
end
canary_runs = canary.dig("jobs", "live-feed", "steps").map { |step| step["run"].to_s }.join("\n")
assert(canary_runs.include?("./gos.sh check"), "canary must run gos check against the live feed")
assert(canary_runs.include?("./gos.sh rollback"), "canary must exercise rollback against a real install")
assert(canary.dig("jobs", "live-feed", "permissions", "issues") == "write", "canary job must be allowed to open its tracking issue")
canary_failure_step = canary.dig("jobs", "live-feed", "steps").find { |step| step["if"].to_s == "failure()" }
assert(canary_failure_step, "canary must open or update a tracking issue when it fails")
assert(canary_failure_step["run"].to_s.include?("gh issue create"), "canary failure step must create an issue")
assert(canary_failure_step["run"].to_s.include?("gh issue comment"), "canary failure step must update an existing open issue instead of duplicating it")
canary_live_steps = canary.dig("jobs", "live-feed", "steps").select { |step| step["run"].to_s.include?("./gos.sh") }
assert(!canary_live_steps.empty?, "canary must define live gos command steps")
canary_live_steps.each do |step|
  timeout = step["timeout-minutes"]
  assert(timeout.is_a?(Integer) && timeout.between?(1, 15), "canary live step #{step["name"]} must set a short timeout so issue reporting can still run")
end
assert(canary_failure_step["timeout-minutes"].is_a?(Integer), "canary issue reporter must have its own timeout")

ci_on = workflow_on(ci)
assert(ci_on.key?("pull_request"), "CI must run on pull_request")
assert(ci_on.dig("push", "branches")&.include?("main"), "CI must run on pushes to main")
assert(ci.dig("permissions", "contents") == "read", "CI must use read-only contents permission")
assert(ci.dig("defaults", "run", "shell") == "bash", "CI must default to bash shell")

ci_jobs = ci.fetch("jobs") { fail!("CI must define jobs") }
%w[shellcheck shfmt smoke workflow-validation actionlint].each do |job|
  assert(ci_jobs.key?(job), "CI must define #{job} job")
end
workflow_validation_runs = ci_jobs.dig("workflow-validation", "steps").map { |step| step["run"].to_s }.join("\n")
actionlint_runs = ci_jobs.dig("actionlint", "steps").map { |step| step["run"].to_s }.join("\n")
assert(ci_jobs.dig("actionlint", "env", "ACTIONLINT_VERSION").to_s.match?(/\A\d+\.\d+\.\d+\z/), "actionlint job must pin an exact rhysd/actionlint release")
assert(actionlint_runs.match?(/^\s*actionlint\s*$/), "actionlint job must lint the workflows")
assert(workflow_validation_runs.include?("bash tests/workflows.bash"), "workflow-validation job must run the invariant suite")
assert(workflow_validation_runs.include?("git diff --check \"$(git hash-object -t tree /dev/null)\" HEAD"), "workflow-validation job must check every tracked file for whitespace errors and conflict markers")

shellcheck_runs = ci_jobs.dig("shellcheck", "steps").map { |step| step["run"].to_s }.join("\n")
assert(shellcheck_runs.include?("shellcheck gos.sh install.sh completions/gos.bash scripts/*.bash scripts/*.sh tests/*.bash"), "ShellCheck job must cover scripts and tests")
assert(ci_jobs.dig("shellcheck", "env", "SHELLCHECK_VERSION").to_s.match?(/\Av\d+\.\d+\.\d+\z/), "ShellCheck job must pin an exact koalaman/shellcheck release")
assert(shellcheck_runs.include?("koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/shellcheck-${SHELLCHECK_VERSION}.linux.x86_64.tar.xz"), "ShellCheck job must install the pinned release binary")
assert(!shellcheck_runs.include?("apt-get install -y shellcheck"), "ShellCheck job must not depend on the runner image package")

shfmt_job = ci_jobs.fetch("shfmt") { fail!("CI must define shfmt job") }
assert(shfmt_job["runs-on"] == "ubuntu-latest", "shfmt job must run on ubuntu")
assert(shfmt_job.dig("env", "SHFMT_VERSION").to_s.match?(/\Av\d+\.\d+\.\d+\z/), "shfmt job must pin an exact mvdan/sh release")
shfmt_runs = shfmt_job.fetch("steps").map { |step| step["run"].to_s }.join("\n")
assert(shfmt_runs.include?("mvdan/sh/releases/download/${SHFMT_VERSION}/shfmt_${SHFMT_VERSION}_linux_amd64"), "shfmt job must install pinned release binary")
assert(shfmt_runs.include?("shfmt -d -i 2 -ci -bn ."), "shfmt job must enforce repo formatting")

matrix_os = ci_jobs.dig("smoke", "strategy", "matrix", "os") || []
%w[ubuntu-latest macos-latest windows-latest].each do |os|
  assert(matrix_os.include?(os), "smoke matrix must include #{os}")
end

smoke_runs = ci_jobs.dig("smoke", "steps").map { |step| step["run"].to_s }.join("\n")
smoke_steps = ci_jobs.dig("smoke", "steps")
parser_dependencies = step_named(smoke_steps, "Require feed parser matrix dependencies")
assert(parser_dependencies, "smoke job must require jq and python3 for the feed parser matrix")
assert(parser_dependencies["if"] == "runner.os != 'Windows'", "feed parser dependencies must be required wherever feature tests run")
parser_dependency_run = parser_dependencies["run"].to_s
assert(parser_dependency_run.include?("command -v jq") && parser_dependency_run.include?("command -v python3"), "feed parser dependency step must fail when jq or python3 is unavailable")
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
psscriptanalyzer = step_named(smoke_steps, "PSScriptAnalyzer")
assert(psscriptanalyzer["run"].to_s.include?("-Severity Error -ErrorAction Stop"), "PowerShell analyzer invocation failures must terminate the gate")
assert(psscriptanalyzer && psscriptanalyzer["if"] == "runner.os == 'Windows'" && psscriptanalyzer["run"].to_s.include?("Invoke-ScriptAnalyzer"), "smoke job must run PSScriptAnalyzer on Windows")
bash32 = step_named(smoke_steps, "Bash 3.2 compatibility")
assert(bash32, "smoke job must exercise the bash 3.2 floor")
assert(bash32["if"] == "runner.os == 'macOS'", "bash 3.2 compatibility step must run on macOS, the only runner shipping bash 3.2")
assert(bash32["run"].to_s.include?("grep -F 'version 3.2'") && bash32["run"].to_s.include?("bash scripts/run-tests.bash") && bash32["run"].to_s.lines.any? { |line| line.strip == "bash scripts/run-tests.bash --jobs 2" }, "bash 3.2 compatibility step must verify the interpreter and run the feature suites under it")
assert(command_surface_sync, "smoke job must check generated command surfaces")
assert(command_surface_sync["run"].to_s.include?("bash scripts/sync-command-surfaces.bash --check"), "command surface sync must use the orchestrator")

[
  "bash scripts/run-tests.bash",
  "bash scripts/sync-command-surfaces.bash --check",
  "git ls-files -z '*.sh' '*.bash' | xargs -0 -n 1 bash -n --",
  "./gos.sh version",
  "./gos.sh help",
  "zsh -n completions/gos.zsh",
  "fish --no-config --no-execute completions/gos.fish"
].each do |command|
  assert(smoke_runs.include?(command), "smoke job must run #{command}")
end
# The Bash syntax step derives its file list from git, so every tracked shell
# file is covered by construction; validate-local keeps the explicit list and
# the set-equality assertion above keeps the two in agreement.
bash_syntax = step_named(smoke_steps, "Bash syntax")
assert(bash_syntax, "smoke job must define Bash syntax step")
assert(bash_syntax["run"].to_s.include?("git ls-files -z '*.sh' '*.bash' | xargs -0 -n 1 bash -n --"), "smoke job Bash syntax must derive a NUL-delimited file list from git ls-files")
tracked_powershell_files.each do |path|
  assert(smoke_runs.include?(path), "smoke job PowerShell syntax must cover tracked PowerShell file #{path}")
end
assert(!smoke_runs.match?(%r{bash tests/}), "smoke job must run suites through scripts/run-tests.bash, not hand-listed bash tests/ commands")
assert(smoke_runs.include?("packaging/chocolatey/tools/chocolateyInstall.ps1"), "smoke job must parse the Chocolatey PowerShell installer")
assert(smoke_runs.include?("packaging/chocolatey/tools/chocolateyUninstall.ps1"), "smoke job must parse the Chocolatey PowerShell uninstaller")
assert(smoke_runs.include?("packaging/windows/uninstall.ps1"), "smoke job must parse the Windows PowerShell uninstaller")
assert(smoke_runs.include?("tests/install-ps1.ps1"), "smoke job must parse the PowerShell installer test")
assert(smoke_runs.include?("powershell -NoProfile -ExecutionPolicy Bypass -File tests/install-ps1.ps1"), "smoke job must run the functional PowerShell installer test")

packaging_files = Dir.glob("packaging/**/*").select { |path| File.file?(path) }
packaging_text = packaging_files.map { |path| File.read(path) }.join("\n")
[
  "packaging/README.md",
  "packaging/Formula/gos.rb",
  "install.ps1",
  "scripts/build-windows-package.bash",
  "scripts/sync-command-surfaces.bash",
  "scripts/update-changelog.bash",
  "scripts/update-homebrew-tap.sh",
  "scripts/update-packaging.bash",
  "scripts/validate-local.bash",
  "packaging/windows/gos.cmd",
  "packaging/windows/uninstall.ps1",
  "tests/install-ps1.ps1",
  "tests/changelog.bash",
  "tests/lib-features.bash",
  "tests/side-by-side.bash",
  "scripts/run-tests.bash",
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
assert(bash_completion.include?("install | platforms)") && bash_completion.include?("run | each)"), "Bash completion must complete install/platforms and run/each versions")
assert(zsh_completion.include?("install)") && zsh_completion.include?("run | each)"), "Zsh completion must complete install and run/each versions")
assert(fish_completion_file.include?("__gos_using_command install platforms") && fish_completion_file.include?("__gos_using_command run each; and __gos_wants_version"), "Fish completion must complete install/platforms and run/each versions")
assert(fish_completion_file.include?("function __gos_needs_command"), "Fish completion must keep offering commands after a leading --json")
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
assert(contributing.include?("workflow YAML parse"), "CONTRIBUTING must document workflow YAML validation")
assert(contributing.include?("Ruby is required for the workflow YAML parse checks"), "CONTRIBUTING must document required Ruby dependency")
assert(contributing.include?("scripts/validate-local.bash --required-only"), "CONTRIBUTING must document required-only validation mode")
assert(contributing.include?("docs/ARCHITECTURE.md"), "CONTRIBUTING must point contributors at docs/ARCHITECTURE.md")
architecture = file_text("docs/ARCHITECTURE.md")
assert(!architecture.empty?, "repository must include docs/ARCHITECTURE.md")
["_gos_command_manifest", "GOS_ACTIVATION_BACKUP", ".gos-rollback", "bash 3.2", "sync-command-surfaces.bash"].each do |fragment|
  assert(architecture.include?(fragment), "docs/ARCHITECTURE.md must mention #{fragment}")
end
assert(contributing.include?("`./gos.sh version`") && contributing.include?("`./gos.sh help`") && contributing.include?("CLI smoke checks"), "CONTRIBUTING must document local CLI smoke checks")
assert(contributing.include?("optional") && contributing.include?("ShellCheck/shfmt/zsh/Fish/PowerShell checks"), "CONTRIBUTING must explain optional local validation tools")

[
  "pwsh",
  "powershell",
  "install.ps1",
  "packaging/chocolatey/tools/chocolateyInstall.ps1",
  "packaging/chocolatey/tools/chocolateyUninstall.ps1",
  "packaging/windows/uninstall.ps1",
  "tests/install-ps1.ps1",
  "foreach ($file in $args)",
  '"${powershell_files[@]}"',
  "run_quiet ./gos.sh help",
  "require_tool ruby",
  "missing required tool: %s (%s)",
  "--required-only",
  "optional checks disabled",
  'Dir[".github/workflows/*.{yml,yaml}"]',
  'abort "no GitHub Actions workflows found"',
  "workflows.each { |path| YAML.load_file(path) }"
].each do |fragment|
  assert(validate_local.include?(fragment), "validate-local must include #{fragment}")
end

[
  "scripts/validate-local.bash",
  "scripts/validate-local.bash --required-only",
  "optional local-tool skips noted",
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
  "scripts/update-packaging.bash",
  "scripts/update-aur.bash",
  "Dir[\".github/workflows/*.{yml,yaml}\"]"
].each do |fragment|
  assert(releasing.include?(fragment), "RELEASING.md must mention #{fragment}")
end
assert(releasing.include?("Start with the full orchestrator"), "RELEASING.md must explain full local validation orchestration")
assert(releasing.include?("release-candidate evidence explicit for CI/release parity"), "RELEASING.md must explain expanded release validation commands")
assert(releasing.include?("scripts/validate-local.bash --required-only") && releasing.include?("only for non-release local") && releasing.include?("triage, and note any optional local-tool skips"), "RELEASING.md must keep required-only out of release-candidate validation")
assert(releasing.include?("```bash\nscripts/validate-local.bash"), "RELEASING.md validation must start with local validation orchestrator")
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

# Every helper that builds a path under GOS_CACHE_DIR must have a
# counterpart in cmd_prune. Without this, adding a new kind of cache file
# leaves it leaking forever — exactly how the discovery feed cache grew
# unreclaimed until v1.8.1.
gos_sh = file_text("gos.sh")
cmd_prune_body = gos_sh[/^cmd_prune\(\) \{.*?^\}/m]
assert(!cmd_prune_body.nil?, "could not locate cmd_prune in gos.sh")

cache_path_producers = gos_sh.scan(/^(_gos_\w+)\(\) \{/).flatten.select do |fn|
  body = gos_sh[/^#{Regexp.escape(fn)}\(\) \{.*?^\}/m]
  body && body =~ /printf\s+'[^']*%s[^']*'\s+"\$GOS_CACHE_DIR"/
end
assert(!cache_path_producers.empty?, "found no GOS_CACHE_DIR path helpers to check (regex drift?)")

# How cmd_prune reclaims each producer's files: the archive helper is globbed,
# the feed helper is called by name.
prune_coverage = {
  "_gos_cache_path" => cmd_prune_body.include?("/go*.tar.gz") && cmd_prune_body.include?("/go*.zip"),
  "_gos_feed_cache_path" => cmd_prune_body.include?("_gos_feed_cache_path"),
}
cache_path_producers.each do |fn|
  assert(prune_coverage.key?(fn),
    "cache-path helper #{fn} has no cmd_prune cleanup mapping: add it to cmd_prune and to this invariant")
  assert(prune_coverage[fn],
    "cmd_prune no longer reclaims the files produced by #{fn}")
end

# Errors should tell the user what to do next, not guess. The old
# archive-download failure blamed "Version may not exist" even on a network
# outage; keep that vague phrasing from creeping back.
# Usage lines in argument errors come from the manifest (_gos_usage); a literal
# is only allowed for the hidden __ commands that the manifest does not list.
gos_sh.each_line do |line|
  next unless line =~ /echo "Usage: gos ([^ "]+)/
  assert(Regexp.last_match(1).start_with?("__"), "gos.sh must print usage through _gos_usage instead of a literal for #{Regexp.last_match(1)}")
end

# The section map at the top of gos.sh must list exactly the section headers
# that exist, in order, so it stays a usable index.
map_sections = gos_sh.scan(/^#   (Helpers|Go downloads feed|Commands|Entrypoint) /).flatten
real_sections = gos_sh.scan(/^# [^A-Za-z\s]+ ([A-Za-z ]+?) [^A-Za-z\s]+$/).flatten.map(&:strip)
assert(map_sections == real_sections, "gos.sh section map #{map_sections.inspect} must match the section headers #{real_sections.inspect}")

# Every user-facing variable gos.sh reads must be in the environment manifest
# (gos __env), which generates the README table and the man page ENVIRONMENT
# section. Internal state variables are recognised by prefix.
env_manifest = `bash gos.sh __env`.lines.map { |line| line.split("|").first }
assert($?.success? && !env_manifest.empty?, "gos __env must print the environment manifest")
internal_prefixes = %w[GOS_AUTO_ GOS_DOCTOR_ GOS_EXIT_ GOS_FEED_JSON GOS_FEED_PARSER GOS_LAST_ERROR GOS_OUTPUT_JSON GOS_PS_ GOS_SUDO_TARGET GOS_ACTIVATION_BACKUP GOS_COMPLETED_PARTIAL GOS_TMP_DIR GOS_LOCK_DIR GOS_RELEASE_BASE_URL GOS_VERSION GOS_JSON_COMMANDS GOS_PROGRESS_FD GOS_VERSIONS_MODE_EXAMPLE GOS_TEST_]
gos_sh.scan(/\$\{(GOS_[A-Z0-9_]+|NO_COLOR|TERM|XDG_[A-Z0-9_]+|GOTOOLCHAIN)[:}-]/).flatten.uniq.each do |name|
  next if internal_prefixes.any? { |prefix| prefix.end_with?("_") ? name.start_with?(prefix) : name == prefix }
  assert(env_manifest.include?(name), "gos.sh reads #{name} but _gos_env_manifest does not document it")
end
%w[GOS_BIN_DIR GOS_HOME GOS_WINDOWS_PACKAGE_PATH GOS_WINDOWS_PACKAGE_SHA256].each do |name|
  assert(env_manifest.include?(name), "installer variable #{name} must be in _gos_env_manifest")
end
assert(readme.include?("<!-- gos-env:begin -->"), "README configuration table must be generated from gos __env")
assert(readme.include?("## Troubleshooting"), "README must keep a Troubleshooting section")
assert(readme.include?("gos prune --rollback   # remove known cached archives"), "README uninstall must cover what gos managed, not only the command")
assert(security.include?("gh attestation verify gos.sh --repo johnny4young/gos"), "SECURITY.md must show how to verify the release attestations")

assert(!gos_sh.include?("may not exist"),
  "download errors must give a next step (retry / gos list), not guess 'may not exist'")

puts "ok - workflow YAML and invariants"
RUBY
