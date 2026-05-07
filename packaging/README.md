# Packaging

`gos` is designed to be easy to install and keep current through the channel a
developer already uses. Homebrew is the active package-manager channel today.
PowerShell is the first-class Windows installer path, and Chocolatey/Winget
metadata stays here as a follow-up distribution layer over the same Windows
release asset.

## Channel Status

| Channel | Status | Notes |
|---|---|---|
| GitHub release installer | Active | Canonical `curl | bash` path for stable releases. |
| Homebrew | Active | Updated by the release workflow through `johnny4young/homebrew-gos`. |
| PowerShell | Prepared | Release workflow publishes `install.ps1` and `gos-windows.zip` as the canonical Windows install path. |
| Chocolatey | Draft | Should wrap the Windows release asset after registry publication is ready. |
| Winget | Draft | Should consume the Windows release asset after manifest validation and registry publication are ready. |

Do not advertise `choco install gos` or `winget install johnny4young.gos` in the
public README until the packages have been accepted by their registries.

## Maintenance Rules

- Package metadata must never point at stale historical release assets.
- Package metadata must never contain placeholder checksums.
- The Windows release asset must contain `gos.sh`, `gos.cmd`, and
  `uninstall.ps1`.
- `install.ps1` must verify the Windows package SHA256 when patched by the
  release workflow.
- Chocolatey downloads must use GitHub release assets, not raw branch URLs.
- Chocolatey and Winget should use the dedicated Windows release asset before
  they are submitted for publication.
- Release automation should eventually update GitHub assets, Homebrew,
  Chocolatey, Winget, README status, and changelog links from the same version.
