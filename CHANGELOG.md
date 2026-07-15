# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Add `scripts/validate-local.bash --required-only` so contributors can run required validation gates while explicitly skipping optional local tools.
- Show curl/wget download progress for archive downloads only when stderr is an interactive TTY, while keeping pipes, JSON, and CI output quiet.
- Style interactive `gos doctor` checks and stderr `Error:`/`Warning:` lines with color and symbols while honoring `NO_COLOR`, `GOS_NO_COLOR=1`, pipes, and JSON output.
- Add a best-effort `gos` self-version check to `gos check`, including JSON metadata and a `gos self-update` hint when a newer release is available.
- Add a pinned `shfmt` CI check and apply the initial repository shell formatting pass.
- Harden feature tests for semantic Go version sorting and `gos self-update` replacement failures.
- Add a shared shell test helper library and continue migrating shell suites to it.

### Changed

- Clarify the release checklist around curated `Unreleased` notes, fallback changelog generation, and the current validation bundle.
- Include and harden Chocolatey PowerShell scripts in local and CI syntax validation, with workflow invariants that keep tracked shell/PowerShell files covered by `scripts/validate-local.bash`.
- Harden Windows package metadata helpers so they reject ambiguous usage, avoid partial Chocolatey/Winget rewrites, and refuse placeholder SHA256 checksums.
- Harden release-note and Homebrew tap helpers with strict input validation, data-safe template rendering, and exact metadata-stanza checks before publication.
- Remove temporary Homebrew tap checkouts after successful, failed, and idempotent publication attempts.
- Preserve changelog permissions during atomic release rewrites, reject invalid release dates and previous tags, and require exactly one Chocolatey, Winget, and workflow version field before publication.
- Make command-surface regeneration transactional so late generator failures restore README, `gos.sh`, and standalone completions without changing their contents or file modes.
- Reject invalid `install.sh` arguments and ambiguous `GOS_BIN_DIR` paths before network access, and keep optional gos release checks HTTPS-only, time-bounded, restricted to canonical tags from this repository, and reported only when semantically newer.

### Security

- Keep curl redirects HTTPS-only for Go feeds, archives, checksum manifests, and self-update assets, and refuse self-update releases with malformed or older versions before replacement.
- Pass Homebrew tap deploy-key paths to SSH as opaque arguments so shell syntax in caller-provided filenames cannot execute.

## [1.7.0] - 2026-07-14

### Added

- Add `gos completions <bash|zsh|fish>` so single-file installs can print shell completions without needing the repository checkout.
- Add `.tool-versions` support to `gos use` for asdf/mise-style `golang` or `go` version files.
- Add "Did you mean?" suggestions for unknown command prefixes.
- Add offline introspection commands: `gos status` for a local dashboard and `gos which [version]` for active or side-by-side Go paths.
- Add a discovery-only Go feed cache for `list`, `platforms`, `check`, and shell completion version suggestions, controlled by `GOS_FEED_TTL`.
- Add dynamic installed/cached version suggestions to Bash, Zsh, and Fish completions without making completion paths touch the network.
- Add a portable `.gos-lock` around mutating commands so concurrent installs, switches, rollbacks, uninstalls, and rollback pruning fail fast instead of racing.
- Add `gos doctor --fix` for safe, idempotent setup fixes: create missing install parents/cache directories and print the shell setup line without editing shell files.
- Add `gos run <version> [--] <command>` to run commands with side-by-side Go versions without changing the active global install.
- Add `gos env --auto` and `gos env --auto --fish` to emit opt-in per-shell hooks that switch `PATH` to installed project versions without mutating global state.

### Changed

- Clarify README completion setup: Homebrew installs completion files automatically; other install methods should use `gos completions <shell>`.
- Fix the README `gos list` example to show the real ascending version order.
- Harden feature tests with parseable-JSON checks, plain `gos list` ordering coverage, strict feed-checksum mode coverage, hostile `gos env` quoting cases, and mirror trailing-slash normalization.

## [1.6.0] - 2026-07-06

### Added

- Add opt-in side-by-side version management: with `GOS_VERSIONS_DIR` set, every Go version stays installed under its own directory, `GOS_INSTALL_DIR` becomes a symlink to the active one, switching is an instant re-link, and `gos uninstall <version>` plus `gos list --installed` manage the set.
- Add `gos env [--fish] [--json]` to print the PATH setup line for the managed Go (`eval "$(gos env)"`).
- Add `GOS_REQUIRE_CHECKSUM=feed` to require the archive digest to come from the go.dev downloads feed (cross-origin), rejecting the same-origin `.sha256` fallback.
- Add a nightly canary workflow that exercises `check`, `install`, `latest`, `rollback`, and side-by-side mode against the live go.dev feed on Linux, macOS, and Windows.
- Add functional tests for the Homebrew tap publish script against a local tap repository (which caught and fixed a first-publish bug: the tap's `Formula/` directory is now created when missing).
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

- Interrupted activations now restore the previous installation from an exit trap — including a root-owned install, which the trap now restores with sudo — and the backup stays armed through validation so an interrupt during a validation-failure restore is still recovered. `gos prune` reports (and `--rollback` removes) orphaned crash-residue backups.
- `gos install`/`gos latest` no longer skip installing when a matching `go` elsewhere on `PATH` masks a missing or stale managed install.
- `_gos_sudo` keeps command stdout and stderr separate, so tool warnings no longer leak into data output.
- The Homebrew tap publish pins GitHub's SSH host keys (fetched over TLS from the GitHub meta API) instead of trust-on-first-use.
- The Windows installer and uninstaller edit the user `PATH` through the registry API, preserving `REG_EXPAND_SZ` values and broadcasting the environment change.
- The changelog release helper now fails on a heading-only `Unreleased` section instead of silently discarding curated headings.
- `gos list` now orders pre-releases semantically: `1.24rc2` sorts before `1.24.0` instead of interleaving with patch releases.
- A broken `go` binary on `PATH` (wrong architecture, corrupt install) no longer aborts `gos current`, `gos install`, or `gos latest`; gos now treats it as "no Go installed" and can repair it.
- Trailing slashes in `GOS_INSTALL_DIR` are normalized, so backups and rollbacks are siblings of the install directory instead of failing inside it.
- `GOS_INSTALL_DIR` values containing `.`/`..` components or control characters are rejected, closing a textual bypass of the system-critical path denylist.
- `gos latest` on a machine without Go prints `Current: none` instead of `Current: gonone`.
- `gos doctor` no longer reports a false checksum-tool warning when gos runs from stdin (`curl | bash -s doctor`), resolves symlinked installs when checking completions, and recognizes `go.exe` under the install dir on Windows.
- `gos platforms` without `jq`/`python3` no longer emits source/installer artifacts (e.g. `go1.x.src.tar.gz`) as bogus platforms, and the last-resort feed parser no longer drops rc/beta versions.
- All single-purpose commands (`install`, `uninstall`, `latest`, `platforms`, `use`, `pin`, `rollback`, `self-update`) reject unexpected trailing arguments instead of silently ignoring them, and `gos check`/`current`/`version`/`doctor` reject unknown flags.
- `gos uninstall` resolves a bare `X.Y` to the matching installed patch release (like `gos install`), and its active-version guard compares by device and inode so a differently spelled but equivalent versions directory cannot bypass it.
- Rollback save and `gos prune` handle a dangling rollback symlink left after uninstalling its target, replacing it instead of stranding the newly saved backup.
- `gos doctor`'s checksum-hash check now hashes a throwaway file, catching a present-but-broken SHA256 tool, and `_gos_self_path` resolves symlinks without `realpath` on older macOS.
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

### Security

- `gos env` now single-quotes the emitted `PATH` entry, so a `GOS_INSTALL_DIR` containing shell metacharacters can no longer inject commands when the documented `eval "$(gos env)"` (or `gos env --fish | source`) runs.
- `gos self-update` now fails closed: it refuses to replace the running script when the release `checksums.txt` manifest is missing or unreadable, instead of proceeding with an unverifiable download.

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


[Unreleased]: https://github.com/johnny4young/gos/compare/v1.7.0...HEAD
[1.7.0]: https://github.com/johnny4young/gos/compare/v1.6.0...v1.7.0
[1.6.0]: https://github.com/johnny4young/gos/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/johnny4young/gos/compare/v1.4.3...v1.5.0
[1.4.3]: https://github.com/johnny4young/gos/compare/v1.4.2...v1.4.3
[1.4.2]: https://github.com/johnny4young/gos/releases/tag/v1.4.2
[1.4.1]: https://github.com/johnny4young/gos/releases/tag/v1.4.1
[1.4.0]: https://github.com/johnny4young/gos/releases/tag/v1.4.0
[1.3.0]: https://github.com/johnny4young/gos/releases/tag/v1.3.0
[1.1.0]: https://github.com/johnny4young/gos/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/johnny4young/gos/releases/tag/v1.0.0
