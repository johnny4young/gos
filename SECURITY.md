# Security Policy

## Supported Versions

Security fixes are released for the latest published `gos` version. Older
versions are not backported; users should upgrade to the newest release when a
fix is published.

The `main` branch can contain unreleased fixes, but stable installs should use
GitHub release assets unless a maintainer asks you to test an unreleased change.

## Reporting a Vulnerability

Use GitHub Security Advisories for private vulnerability reports:

https://github.com/johnny4young/gos/security/advisories/new

Do not open public issues for sensitive reports, exploit details, private
tokens, or machine-specific paths that should not be disclosed. If GitHub does
not allow you to open a private advisory, contact the maintainer through GitHub
with a short request for a private channel and leave technical details out of
the public message.

Useful reports include:

- affected `gos` version or commit
- operating system, shell, and install method
- exact command that triggered the issue
- expected behavior and observed behavior
- minimal reproduction steps
- whether the issue can modify files outside the intended install paths

Best-effort response targets:

- acknowledge the report within 7 days
- confirm impact and affected versions before public disclosure
- publish a fix, mitigation, or status update within 14 days when practical
- credit reporters in the release notes unless they prefer to stay anonymous

## Security Scope

In scope:

- `gos.sh`
- `install.sh`
- `install.ps1`
- Windows packaging shims and uninstall scripts
- release workflow behavior
- checksum and archive extraction logic
- documentation that could direct users to unsafe install paths

Out of scope:

- vulnerabilities in Go itself; report those to the Go security team
- vulnerabilities in GitHub, Homebrew, Chocolatey, Winget, Git Bash, WSL, or
  PowerShell
- issues that require a user to intentionally run modified scripts from an
  untrusted fork

## Trust Model

`gos` installs official Go toolchains from `https://go.dev/dl/`. It does not
build Go from source and does not mirror Go archives.

For Go toolchain installs:

- `gos latest` reads the default Go downloads feed.
- `gos install <version>` reads the full Go downloads feed with `include=all`
  so older pinned versions can still resolve published SHA256 metadata.
- When checksum metadata and a local SHA256 tool are available, `gos` verifies
  the downloaded archive before replacing the active Go installation.
- `GOS_REQUIRE_CHECKSUM=1` makes checksum metadata and local hash calculation
  mandatory, causing installs to fail closed when verification cannot run.
- Go replacement is transactional: the new archive is staged, verified,
  activated, and rolled back if activation fails.

For `gos` installer assets:

- The recommended macOS/Linux/Git Bash install path downloads
  `https://github.com/johnny4young/gos/releases/latest/download/install.sh`.
- Release `install.sh` is patched with the expected `gos.sh` SHA256 before
  publication.
- Release `install.ps1` is patched with the expected `gos-windows.zip` SHA256
  before publication.
- `checksums.txt` is published with `gos.sh`, `install.sh`, `install.ps1`, and
  `gos-windows.zip`.
- Release assets and `checksums.txt` receive GitHub artifact attestations.

Raw `main` installer URLs are a development channel. They are useful for testing
unreleased changes, but they intentionally do not provide the same
release-pinned checksum path as published release assets.
