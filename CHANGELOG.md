# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/johnny4young/gos/compare/v1.4.2...HEAD
[1.4.2]: https://github.com/johnny4young/gos/releases/tag/v1.4.2
[1.4.1]: https://github.com/johnny4young/gos/releases/tag/v1.4.1
[1.4.0]: https://github.com/johnny4young/gos/releases/tag/v1.4.0
[1.3.0]: https://github.com/johnny4young/gos/releases/tag/v1.3.0
[1.1.0]: https://github.com/johnny4young/gos/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/johnny4young/gos/releases/tag/v1.0.0
