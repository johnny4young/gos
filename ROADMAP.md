# Roadmap and Security Plan

Created: 2026-05-06

This plan is based on a local review of `gos.sh`, `install.sh`, completions,
packaging manifests, the release workflow, the latest GitHub release, and the
Go downloads API.

## Current Snapshot

- Current CLI version in `gos.sh`: `1.4.2`.
- Latest published GitHub release checked during review: `v1.4.2`.
- Latest release assets checked during review: `gos.sh`, `install.sh`, and
  `checksums.txt`.
- Local branch state during review: `main` matched `origin/main`.
- Basic local validation passed:
  - `bash -n gos.sh install.sh completions/gos.bash`
  - `zsh -n completions/gos.zsh`
  - `./gos.sh version`
  - `./gos.sh help`
  - `./gos.sh current`
- `shellcheck` was not installed locally, so ShellCheck coverage should be added
  to CI instead of relying on local developer setup.

## Summary

The core script already has useful hardening: `set -euo pipefail`, strict HTTPS
downloads, version validation, temporary directories via `mktemp`, checksum
verification when metadata and hash tools are available, and guardrails around
dangerous install paths.

The main remaining risks are supply-chain and installer reliability issues:

- `gos.sh` removes the current Go installation before the new archive is fully
  extracted and validated.
- Checksum lookup for old pinned Go versions can silently miss metadata because
  it queries the default Go downloads feed instead of the full feed.
- The README promotes the raw `main` installer path, which bypasses the patched
  release checksum path.
- The release workflow grants repository write permission to every job and does
  not validate tag-push releases with the same semver gate used for manual
  releases.
- Windows packaging files are stale and still reference `1.0.0` or placeholder
  checksums while the public release is `1.4.2`.

## P0 - Security and Data-Loss Prevention

### SEC-001: Make Go installation transactional

Evidence: `gos.sh:249-270` removes `$GOS_INSTALL_DIR` before extraction is
complete.

Risk: A failed download, extraction error, permission problem, interrupted
process, or malformed archive can leave the user without a working Go install.

Plan:

- Extract the new Go archive into a temporary staging directory first.
- Validate that the staged tree contains `go/bin/go`.
- Move the existing install to a backup path instead of deleting it immediately.
- Move the staged install into place.
- Roll back from the backup if activation fails.
- Delete the backup only after `go version` succeeds from the target path.

Acceptance criteria:

- A forced extraction failure leaves the previous Go installation intact.
- A successful install replaces the old version and removes temporary state.
- Tests cover default and custom `GOS_INSTALL_DIR` paths.

### SEC-002: Verify checksums for historical pinned versions

Evidence: `_gos_fetch_checksum` in `gos.sh:132-153` queries
`https://go.dev/dl/?mode=json`, while old versions such as `go1.21.6` appear in
`https://go.dev/dl/?mode=json&include=all`.

Risk: `gos install <old-version>` can fall back to a warning and continue
without integrity verification even when Go publishes the expected checksum.

Plan:

- Query the full Go downloads feed for explicit version installs.
- Keep the default feed for `gos latest` if needed for speed.
- Add a strict mode such as `GOS_REQUIRE_CHECKSUM=1`.
- Consider failing closed by default when checksum metadata exists but cannot be
  parsed.

Acceptance criteria:

- `gos install 1.21.6` can resolve the expected SHA256 from the full feed.
- A checksum mismatch aborts before any install path is modified.
- Missing checksum tooling produces a clear message and documented behavior.

### SEC-003: Prefer verified release installer paths

Evidence: `README.md:61`, `README.md:106`, and `README.md:112` use the raw
`main` installer URL. The release asset installer is patched with
`GOS_RELEASE_TAG` and `GOS_EXPECTED_SHA256`.

Risk: The most visible installation path bypasses the release-pinned checksum
flow.

Plan:

- Make the default quick-start command use
  `https://github.com/johnny4young/gos/releases/latest/download/install.sh`.
- Keep the raw `main` installer only as a development-channel option.
- Fix the custom install example so `GOS_BIN_DIR` is passed to `bash`, not only
  to `curl`.

Acceptance criteria:

- README quick start installs through the release asset path.
- Custom bin-dir install works with a one-liner.
- Documentation clearly distinguishes stable release install from development
  install.

### SEC-004: Harden GitHub Actions permissions and tag validation

Evidence: `.github/workflows/release.yml:13-15` grants `contents: write` at
workflow scope. `.github/workflows/release.yml:3-7` accepts all `v*` tag pushes,
while version validation only runs for `workflow_dispatch` at
`.github/workflows/release.yml:22-28`.

Risk: Jobs that only need read access still receive write access, and malformed
tags can enter the release flow. A stale `vv.1.1.0` tag exists locally and
remotely, which shows why the tag gate should be stricter.

Plan:

- Set top-level workflow permissions to `contents: read`.
- Grant `contents: write` only to release/version/tag jobs that need it.
- Add a shared validation job for both `workflow_dispatch` and tag push events.
- Use environment variables for workflow input values before shell execution.
- Add artifact attestations for released assets.

Acceptance criteria:

- Smoke-test jobs run with read-only permissions.
- Release jobs fail fast for non-semver tags.
- Released `gos.sh`, `install.sh`, and `checksums.txt` have provenance
  attestations.

### SEC-005: Remove PowerShell command-string interpolation in Windows fallback

Evidence: `gos.sh:258-260` builds a PowerShell command string with converted
paths.

Risk: User-controlled install paths are validated for broad safety, but they are
still safer when passed as arguments or environment variables instead of
embedded into a command string.

Plan:

- Prefer `unzip` or `tar` on Windows Git Bash when available.
- If PowerShell remains as a fallback, pass paths via environment variables and
  use `-LiteralPath`.
- Add Windows CI coverage for paths with spaces and quotes.

Acceptance criteria:

- Windows extraction handles spaces safely.
- A path containing quotes does not break command parsing.
- The fallback is covered in CI or an isolated test harness.

## P1 - Reliability and Test Coverage

### REL-001: Add a non-destructive test harness

Plan:

- Add tests that shadow `curl`, `wget`, `tar`, `unzip`, `go`, and checksum tools
  with fake commands in a temporary `PATH`.
- Run install flows only against temporary directories.
- Cover validators, checksum mismatch, missing parser tools, failed extraction,
  custom install dirs, and command dispatch.

Acceptance criteria:

- Tests can run locally without downloading or replacing Go.
- Tests fail if install logic touches `/usr/local/go`.
- Tests are wired into CI.

### REL-002: Add ShellCheck and cross-platform CI

Plan:

- Add a CI workflow for ShellCheck.
- Run smoke tests on Linux, macOS, and Windows Git Bash.
- Validate Bash, Zsh, and Fish completions where shells are available.

Acceptance criteria:

- Pull requests run syntax checks and ShellCheck.
- Windows support claimed in the README is validated in CI.

### REL-003: Repair changelog automation

Evidence: `CHANGELOG.md:7-9` contains empty `1.4.2` and `1.4.1` sections, and
`CHANGELOG.md:27` places `Unreleased` below older releases.

Plan:

- Keep `Unreleased` at the top.
- Avoid empty release sections.
- Generate customer-facing release notes rather than merge-commit text.
- Keep compare links in chronological order.

Acceptance criteria:

- A release with no user-facing changes does not create an empty section.
- `Unreleased` remains immediately after the changelog intro.

### REL-004: Make installer directories explicit

Evidence: `install.sh:63-73` assumes `GOS_BIN_DIR` exists, and `gos.sh` assumes
the parent of `GOS_INSTALL_DIR` exists.

Plan:

- Create user-writable custom directories when possible.
- Fail with a precise message when parent creation requires privileges.
- Document the behavior in the configuration section.

Acceptance criteria:

- `GOS_BIN_DIR="$HOME/.local/bin"` works when the directory does not exist.
- `GOS_INSTALL_DIR="$HOME/.local/go"` works when `$HOME/.local` does not exist.

## P2 - Packaging and Distribution

### PKG-001: Finish or remove stale Windows package manifests

Evidence:

- `packaging/chocolatey/gos.nuspec:5` still declares version `1.0.0`.
- `packaging/chocolatey/tools/chocolateyInstall.ps1:4` downloads `v1.0.0`.
- `packaging/winget/johnny4young.gos.yaml:3` declares version `1.0.0`.
- `packaging/winget/johnny4young.gos.yaml:23` still contains
  `FILL_AFTER_RELEASE`.

Plan:

- Either complete the Winget and Chocolatey publishing flow for `v1.4.2+`, or
  remove/package-hide these manifests until they are ready.
- Generate package checksums during release.
- Add package validation to CI.

Acceptance criteria:

- README installation options match packages that are actually publishable.
- No manifest ships with placeholder checksums.

### PKG-002: Automate package version updates

Plan:

- Update Winget and Chocolatey manifests from the same release version source as
  `gos.sh`.
- Keep Homebrew, GitHub release assets, Winget, Chocolatey, README, and
  changelog in one release checklist.

Acceptance criteria:

- A release cannot complete with stale packaging versions.
- Generated package metadata is validated before publish.

## P3 - Product Features

### FEAT-001: Add project-aware version switching

Plan:

- Add `gos use` to read `.go-version`, `go.mod`, and `toolchain` directives.
- Prefer explicit `.go-version`, then `toolchain`, then `go` directive.
- Add `gos pin <version>` to write `.go-version`.

Acceptance criteria:

- In a project with `.go-version`, `gos use` installs that exact version.
- In a module with `toolchain goX.Y.Z`, `gos use` installs that toolchain.
- Behavior is documented and tested with fixture projects.

### FEAT-002: Add `gos doctor`

Plan:

- Check active `go` path, `GOS_INSTALL_DIR`, write permissions, checksum tools,
  archive tools, shell completions, and PATH ordering.
- Print clear fixes without modifying the system.

Acceptance criteria:

- `gos doctor` exits non-zero only for actionable problems.
- Output stays compact and shell-friendly.

### FEAT-003: Add cache and rollback support

Plan:

- Cache downloaded Go archives under a documented cache directory.
- Verify cached archives by checksum before reuse.
- Add `gos rollback` after transactional installs are implemented.

Acceptance criteria:

- Reinstalling a cached version does not re-download it.
- Cache corruption is detected before install.
- Rollback restores the previous Go version.

### FEAT-004: Add machine-readable output

Plan:

- Add `--json` for `current`, `list`, `version`, and `doctor`.
- Keep human output as the default.

Acceptance criteria:

- JSON output is valid and stable enough for scripts.
- Shell completions include the new flag.

### FEAT-005: Improve version and platform discovery

Plan:

- Derive supported OS/arch combinations from the Go downloads API where
  possible.
- Add support for additional Go archive targets only when install and test
  coverage exists.
- Improve rc/beta parsing for current-version checks.

Acceptance criteria:

- Unsupported platform messages list the detected OS/arch.
- New platform targets have CI or documented manual validation.

## Governance and Maintenance

### GOV-001: Add `SECURITY.md`

Plan:

- Document how to report vulnerabilities.
- Define the support policy for current and older `gos` versions.
- Explain the trust model for Go downloads, GitHub release assets, and checksum
  verification.

Acceptance criteria:

- Security reporting instructions are visible from the repository root.
- Installer trust assumptions are documented in one place.

### GOV-002: Add a release checklist

Plan:

- Document the exact release flow and post-release checks.
- Include GitHub release assets, checksums, Homebrew tap, package manifests,
  README install commands, changelog anchors, and smoke tests.

Acceptance criteria:

- A maintainer can release without relying on memory of prior fixes.
- The checklist prevents stale package metadata and empty changelog sections.

## Suggested First Implementation Slices

1. Documentation and installer trust cleanup:
   - Switch README quick start to the release installer.
   - Fix the `GOS_BIN_DIR` one-liner.
   - Fix git-clone instructions so `gos` is actually available.
   - Move `Unreleased` back to the top of `CHANGELOG.md`.

2. Historical checksum hardening:
   - Query `include=all` for explicit installs.
   - Add tests for old versions and checksum mismatch.

3. Transactional install:
   - Stage, validate, backup, activate, rollback.
   - Add non-destructive install tests.

4. CI baseline:
   - Add ShellCheck.
   - Add Linux/macOS/Windows smoke tests.
   - Add release workflow validation tests.

5. Release supply-chain hardening:
   - Tighten workflow permissions.
   - Validate tag-push semver.
   - Add GitHub artifact attestations.

6. Packaging cleanup:
   - Update or remove stale Winget/Chocolatey manifests.
   - Add package validation to release checks.

## External References

- Go downloads API: https://go.dev/dl/?mode=json
- Full Go downloads API: https://go.dev/dl/?mode=json&include=all
- GitHub Actions workflow permissions:
  https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax
- GitHub Actions script injection guidance:
  https://docs.github.com/en/actions/concepts/security/script-injections
- GitHub artifact attestations:
  https://docs.github.com/actions/concepts/security/artifact-attestations
