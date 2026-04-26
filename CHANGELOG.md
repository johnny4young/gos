# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.4.2] - 2026-04-26

## [1.4.1] - 2026-04-26

### Changed

- Merge pull request #1 from johnny4young/claude/security-code-cleanup-SWsa3

## [1.4.0] - 2026-03-24

### Changed

- update update-formula job to push to homebrew-gos tap repo

## [1.3.0] - 2026-03-24

### Fixed

- add python3 fallback for checksum verification without jq

## [Unreleased]

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

[Unreleased]: https://github.com/johnny4young/gos/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/johnny4young/gos/releases/tag/v1.4.0
[1.3.0]: https://github.com/johnny4young/gos/releases/tag/v1.3.0
[1.1.0]: https://github.com/johnny4young/gos/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/johnny4young/gos/releases/tag/v1.0.0
[1.4.1]: https://github.com/johnny4young/gos/releases/tag/v1.4.1
[1.4.2]: https://github.com/johnny4young/gos/releases/tag/v1.4.2
