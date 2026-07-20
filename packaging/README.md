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
| Homebrew | Active | Updated by the release workflow through the central `johnny4young/homebrew-tap` tap. |
| PowerShell | CI-validated | Release workflow publishes `install.ps1` and `gos-windows.zip` as the canonical Windows install path. |
| Chocolatey | Draft | Metadata wraps the Windows release asset and is updated by release automation. |
| Winget | Draft | Metadata consumes the Windows release asset and is updated by release automation. |
| AUR | Draft | `packaging/aur/PKGBUILD` packages the release source tarball for Arch Linux; published by pushing to the AUR git remote. |

Do not advertise `choco install gos`, `winget install johnny4young.gos`, or
`yay -S gos` in the public README until the packages have been accepted by (or
pushed to) their registries.

## Arch Linux (AUR)

`packaging/aur/` holds a versioned `PKGBUILD` plus its generated `.SRCINFO`. The
package installs `gos.sh` to `/usr/bin/gos`, the three shell completions to their
standard vendor directories, the `gos.1` man page, and the MIT license.

Publishing and bumping are manual maintainer steps (the AUR accepts a package
the moment it is pushed — there is no review queue):

1. Recompute the source digest for the new tag:
   `curl -sL https://github.com/johnny4young/gos/archive/refs/tags/vX.Y.Z.tar.gz | sha256sum`
2. Update `pkgver`, reset `pkgrel=1`, and replace `sha256sums` in `PKGBUILD`, then
   mirror the same `pkgver`/`pkgrel`/`sha256sums` into `.SRCINFO`
   (`makepkg --printsrcinfo > .SRCINFO` on an Arch box regenerates it exactly).
3. `tests/packaging.bash` guards that the two files agree and that every packaged
   path exists before you push.
4. Push to the AUR remote from a checkout of `ssh://aur@aur.archlinux.org/gos.git`
   (requires an AUR account with an SSH key on file).

## Maintenance Rules

- Package metadata must never point at stale historical release assets.
- Package metadata must never contain placeholder checksums.
- The Windows release asset must contain `gos.sh`, `gos.cmd`, and
  `uninstall.ps1`.
- `install.ps1` must verify the Windows package SHA256 when patched by the
  release workflow.
- Chocolatey downloads must use GitHub release assets, not raw branch URLs.
- Chocolatey and Winget use the dedicated Windows release asset before they are
  submitted for publication.
- Release automation updates GitHub assets, Homebrew, Chocolatey, Winget,
  README status, and changelog links from the same version where applicable.
