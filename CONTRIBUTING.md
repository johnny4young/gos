# Contributing to gos

Thanks for helping improve `gos`. This project is a small Bash-based Go
toolchain installer, so the highest-value contributions are reliable fixes,
clear reproductions, safer install behavior, and docs that prevent users from
copying unsafe commands.

## Ways to Help

- Report install, rollback, checksum, PATH, or platform detection bugs.
- Improve macOS, Linux, Windows, Git Bash, WSL, Zsh, Fish, and PowerShell
  compatibility.
- Add focused tests for installer transactions, checksums, packaging, and
  release workflow behavior.
- Improve docs for first-time users and package manager installs.
- Pick issues labeled `good first issue` or `help wanted`.

## Before Opening an Issue

Run:

```bash
gos doctor
gos version
go version
```

For install bugs, include:

- OS and architecture (`uname -s`, `uname -m`, or Windows version)
- shell (`bash --version`, Git Bash, WSL, PowerShell, etc.)
- install method (`curl | bash`, Homebrew, PowerShell, git clone)
- `GOS_INSTALL_DIR`, `GOS_CACHE_DIR`, and relevant PATH entries if customized
- exact command, expected behavior, and observed output
- whether `GOS_REQUIRE_CHECKSUM=1` was set

Do not paste secrets, private paths, or sensitive vulnerability details into a
public issue. Use the process in [SECURITY.md](SECURITY.md) for security
reports.

## Development Setup

Clone the repo and run the script from the checkout:

```bash
git clone https://github.com/johnny4young/gos.git
cd gos
./gos.sh version
./gos.sh help
```

Most tests use fake commands in a temporary PATH and do not touch your real Go
installation.

## Command and Completion Surfaces

Public commands are listed in one place: `_gos_command_manifest` in `gos.sh`.
When you add, rename, remove, or reword a command, update that manifest first
and then regenerate the derived surfaces:

```bash
scripts/sync-command-surfaces.bash --write
```

That command keeps the README Usage table, Bash fallback completions, Fish and
Zsh command descriptions, and embedded completion blocks in sync. Before you
commit, verify the generated files are current:

```bash
scripts/sync-command-surfaces.bash --check
bash tests/completions.bash
```

## Validation

Run the focused checks for your change:

```bash
bash -n gos.sh install.sh
bash tests/install-transaction.bash
bash tests/checksum.bash
bash tests/features.bash
bash tests/detection.bash
```

Before opening a pull request, run the broader local suite when possible:

```bash
scripts/validate-local.bash
```

The local validation script runs command-surface checks, workflow YAML parse
checks, Bash syntax checks, the repository Bash test suite, `./gos.sh version`
and `./gos.sh help` CLI smoke checks, `git diff --check`, and optional
ShellCheck/shfmt/zsh/Fish/PowerShell checks when those tools are installed.
Ruby is required for the workflow YAML parse checks. Use
`scripts/validate-local.bash --required-only` when you need only the required
gates without optional local tooling.

## Pull Request Guidelines

- Keep changes focused and explain the user-visible behavior.
- Add or update tests for installer, rollback, checksum, or release behavior.
- Update README, SECURITY, RELEASING, packaging docs, or changelog text when the
  behavior users rely on changes.
- Avoid live installs in tests unless they are explicitly isolated.
- Preserve the release-asset install path as the trusted default; raw `main`
  URLs are for development testing only.

## Community Standards

Participation in this project is covered by the
[Code of Conduct](CODE_OF_CONDUCT.md).
