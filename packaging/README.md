# Packaging

`gos` is designed to be easy to install and keep current through the channel a
developer already uses. Homebrew is the active package-manager channel today.
Chocolatey and Winget metadata stay in this directory so Windows package support
can be maintained instead of rediscovered later.

## Channel Status

| Channel | Status | Notes |
|---|---|---|
| GitHub release installer | Active | Canonical `curl | bash` path for stable releases. |
| Homebrew | Active | Updated by the release workflow through `johnny4young/homebrew-gos`. |
| Chocolatey | Prepared | Metadata is versioned and checksum-pinned, but registry publication is a separate release step. |
| Winget | Draft | Publishing needs a dedicated Windows-friendly release asset that exposes a `gos` command. |

Do not advertise `choco install gos` or `winget install johnny4young.gos` in the
public README until the packages have been accepted by their registries.

## Maintenance Rules

- Package metadata must never point at stale historical release assets.
- Package metadata must never contain placeholder checksums.
- Chocolatey downloads must use GitHub release assets, not raw branch URLs.
- Winget should use a dedicated release asset instead of GitHub source archives
  before it is submitted for publication.
- Release automation should eventually update GitHub assets, Homebrew,
  Chocolatey, Winget, README status, and changelog links from the same version.
