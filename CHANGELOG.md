# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.2.0] - 2026-03-24

### Changed

- auto-generate CHANGELOG.md from conventional commits on release

## [1.0.0] - 2026-03-23

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
- Shell completions for Bash, Zsh, and Fish
- One-liner installer via `curl | bash`
- Homebrew formula
- Winget manifest
- Chocolatey package

[1.0.0]: https://github.com/johnny4young/gos/releases/tag/v1.0.0
[1.2.0]: https://github.com/johnny4young/gos/releases/tag/v1.2.0
