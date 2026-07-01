# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Add `gos check` to report whether a newer stable Go is available, with `--json` support for scripts and CI.
- Add `gos self-update` to upgrade gos itself from the latest release, verified against the published `checksums.txt` manifest and syntax-checked before activation.
- Add `GOS_DOWNLOAD_MIRROR` to download Go archives from an HTTPS mirror while still verifying official go.dev checksum metadata; unverifiable mirror downloads fail closed.
- Add `gos prune --json` machine-readable output.
- Add `gos install 1.22`-style bare minor versions: they now resolve to the newest matching patch release instead of failing with a 404 (also fixes `gos use` with a `go 1.22` directive in `go.mod`).
- Add `gos prune [--rollback]` to remove cached Go archives and, optionally, the rollback installation.
- Add a `.sha256` companion-file checksum fallback so downloads are verified even without `jq`/`python3`.
- Map `armv7l`/`armv8l` hardware to Go's `armv6l` builds so 32-bit Raspberry Pi OS installs work.

### Changed

- Homebrew install now uses the central `johnny4young/homebrew-tap` tap (`brew install johnny4young/tap/gos`). The deprecated `johnny4young/gos` tap re-points existing users automatically via `tap_migrations.json`, so no manual re-tap is needed. Releases now publish `Formula/gos.rb` to the central tap with the vendored `scripts/update-homebrew-tap.sh`.
- `gos latest` now resolves the version and its checksum from a single downloads-feed request.
- Version listing and latest-version parsing prefer `python3` before falling back to text scraping when `jq` is missing.
- `GOS_INSTALL_DIR` must now be an absolute path.
- Network failures in `latest`, `install`, `list`, and `platforms` now print actionable errors instead of aborting mid-command.
- Download commands use connection timeouts and retries instead of waiting indefinitely.

### Fixed

- `gos list` now orders pre-releases semantically: `1.24rc2` sorts before `1.24.0` instead of interleaving with patch releases.
- A broken `go` binary on `PATH` (wrong architecture, corrupt install) no longer aborts `gos current`, `gos install`, or `gos latest`; gos now treats it as "no Go installed" and can repair it.
- Trailing slashes in `GOS_INSTALL_DIR` are normalized, so backups and rollbacks are siblings of the install directory instead of failing inside it.
- `GOS_INSTALL_DIR` values containing `.`/`..` components or control characters are rejected, closing a textual bypass of the system-critical path denylist.
- `gos latest` on a machine without Go prints `Current: none` instead of `Current: gonone`.
- `gos doctor` no longer reports a false checksum-tool warning when gos runs from stdin (`curl | bash -s doctor`), resolves symlinked installs when checking completions, and recognizes `go.exe` under the install dir on Windows.
- `gos platforms` without `jq`/`python3` no longer emits source/installer artifacts (e.g. `go1.x.src.tar.gz`) as bogus platforms, and the last-resort feed parser no longer drops rc/beta versions.
- `gos install` rejects unexpected trailing arguments instead of silently ignoring them.
- `.go-version`/`go.mod` lookup now also finds manifests at the filesystem root.
- The release workflow now verifies installer patching, pushes the release commit and tag atomically, marks `-rc` versions as pre-releases (keeping them out of `releases/latest` and the Homebrew tap), requires tag-push releases to point at commits on `main`, asserts the stamped `GOS_VERSION` matches the tag, and serializes concurrent runs.
- The Windows release package pins `gos.sh`'s executable bit so the zip checksum cannot drift with checkout file modes.
- The Homebrew tap publish step retries with a rebase when a concurrent sibling release pushes first.
- The changelog release helper no longer trips bash 3.2's empty-array handling when no previous tag exists.
- Interrupted installs no longer leak temporary staging directories; cleanup now runs from an exit trap in `gos.sh` and `install.sh`.
- The Windows installer no longer downgrades TLS 1.3-capable connections to TLS 1.2; it now enforces a TLS 1.2 floor instead.
- `install.sh` executes only after the full script is downloaded and parsed, supports `wget` when `curl` is missing, honors `GOS_REQUIRE_CHECKSUM=1`, and fails with a clear message when sudo is unavailable.
- `gos list --json` no longer emits a truncated JSON document when the feed request fails.
- Sudo retry detection now works on non-English locales.
- `gos doctor` completions check now resolves the script directory correctly when invoked as `bash gos.sh`.
- Feature tests no longer hard-code the released version, and Ruby-based checks run under any locale.

## [1.5.0] - 2026-05-12

### Changed

- Add open source community standards.
- Bump actions/checkout from 5 to 6.
- Accept actions/checkout@v6 in workflow invariants.
- Clarify changelog requirement.

### Fixed

- Preserve rollback backups when install parent needs sudo.
- Retry with sudo on permission errors.
- Generate changelog notes during manual release.

## [1.4.3] - 2026-05-08

### Changed

- Add project-aware version switching with `gos use` and `.go-version` pinning with `gos pin`.
- Add `gos doctor` diagnostics for PATH, permissions, checksum tools, archive tools, and shell completions.
- Add verified archive caching, `gos rollback`, platform discovery, and JSON output for script-friendly commands.
- Add CI coverage for pull requests and pushes across ShellCheck, workflow validation, and Linux/macOS/Windows smoke tests.
- Restore Winget and Chocolatey packaging metadata as a DevEx distribution track, with guardrails against stale versions and placeholder checksums.
- Add PowerShell as the primary Windows installer strategy, with release packaging for a checksum-verified `gos-windows.zip` asset.
- Document that rerunning the PowerShell installer updates `gos` without installing Go by default.
- Add Windows CI coverage that functionally installs, updates, and uninstalls `gos` through `install.ps1`.
- Automate Chocolatey and Winget metadata updates from the same Windows release asset checksum.
- Add a maintainer release checklist covering GitHub assets, Homebrew, PowerShell, package metadata, README commands, changelog anchors, and smoke checks.

### Fixed

- Fix release changelog automation so releases use curated `Unreleased` notes, keep `Unreleased` at the top, and fail instead of creating empty release sections.
- Create missing installer target directories for custom `GOS_BIN_DIR` and `GOS_INSTALL_DIR` paths when possible.

### Security

- Add `SECURITY.md` with vulnerability reporting instructions, supported versions, and the installer trust model.
- Harden Windows zip extraction by preferring `unzip`/`tar` and passing PowerShell fallback paths through environment variables with `-LiteralPath`.
- Harden release workflow permissions, semver tag validation, and artifact provenance attestations for release assets.
- Replace Go installations transactionally so failed extraction or activation keeps the previous install intact.
- Verify checksums for historical Go versions using the full downloads feed, with `GOS_REQUIRE_CHECKSUM=1` for fail-closed installs.

## [1.4.2] - 2026-04-26

### Changed

- Maintenance release with no user-facing changes.

## [1.4.1] - 2026-04-26

### Changed

- Merge pull request #1 from johnny4young/claude/security-code-cleanup-SWsa3

## [1.4.0] - 2026-03-24

### Changed

- update update-formula job to push to homebrew-gos tap repo

## [1.3.0] - 2026-03-24

### Fixed

- add python3 fallback for checksum verification without jq

## [1.1.0] - 2025-03-10

### Added

- Enable release automation via GitHub Actions `workflow_dispatch`
- Add Homebrew tap support and auto-update formula on release
- Verify SHA256 checksum after download

### Fixed

- Clean up temp directory on extraction failure
- Use `$TMPDIR` for temp files, replace emoji with plain text
- Use jq for JSON parsing when available, relax grep pattern
- Replace `sort -V` with numeric sort for portability
- Add wget fallback for systems without curl
- Use sudo only when needed, never on Windows
- Add zip extraction fallbacks for Windows Git Bash

### Security

- Validate version input to prevent path traversal
- Add SHA256 integrity check to install.sh
- Warn user when checksum verification is skipped
- Validate `GOS_INSTALL_DIR` before `rm -rf`
- Use `mktemp` for unique temp directory to prevent TOCTOU attacks
- Only use sudo in install.sh when target dir is not writable
- Use `mktemp` in install.sh instead of hardcoded `/tmp`
- Remove `cmd.exe` call to prevent command injection on Windows
- Document HTTPS/CA trust model in download functions

## [1.0.0] - 2025-01-15

### Added

- `gos latest` — install the latest stable Go version
- `gos install <version>` — install a specific Go version
- `gos current` — show the currently active Go version
- `gos list` — list all available Go versions
- `gos version` — show gos version
- `gos help` — show help message
- Cross-platform support: macOS, Linux, Windows (Git Bash / WSL)
- Auto-detection of OS and CPU architecture
- `GOS_INSTALL_DIR` environment variable for custom install paths
- One-liner installer via `curl | bash`
- Homebrew formula


[Unreleased]: https://github.com/johnny4young/gos/compare/v1.5.0...HEAD
[1.5.0]: https://github.com/johnny4young/gos/compare/v1.4.3...v1.5.0
[1.4.3]: https://github.com/johnny4young/gos/compare/v1.4.2...v1.4.3
[1.4.2]: https://github.com/johnny4young/gos/releases/tag/v1.4.2
[1.4.1]: https://github.com/johnny4young/gos/releases/tag/v1.4.1
[1.4.0]: https://github.com/johnny4young/gos/releases/tag/v1.4.0
[1.3.0]: https://github.com/johnny4young/gos/releases/tag/v1.3.0
[1.1.0]: https://github.com/johnny4young/gos/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/johnny4young/gos/releases/tag/v1.0.0
