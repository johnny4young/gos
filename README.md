<p align="center">
  <h1 align="center">gos</h1>
  <p align="center">
    <strong>Install and switch Go versions in seconds. One script. Zero dependencies.</strong>
  </p>
  <p align="center">
    <a href="https://github.com/johnny4young/gos/releases"><img src="https://img.shields.io/github/v/release/johnny4young/gos" alt="GitHub Release"></a>
    <a href="https://github.com/johnny4young/gos/blob/main/LICENSE"><img src="https://img.shields.io/github/license/johnny4young/gos" alt="License"></a>
    <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-blue" alt="Platform">
    <img src="https://img.shields.io/badge/shell-bash-green" alt="Shell">
    <a href="https://github.com/johnny4young/gos/stargazers"><img src="https://img.shields.io/github/stars/johnny4young/gos?style=social" alt="Stars"></a>
  </p>
</p>

---

## Why gos?

You're on Go 1.19. Your project needs 1.22. You just want to switch — not install a version manager that itself needs managing.

**gos** (Go Switch) is a single Bash script that installs and switches Go versions. That's it. No runtimes, no plugins, no config files. It downloads the official binary from [go.dev](https://go.dev/dl/), puts it in place, and gets out of your way.

```bash
gos latest        # installs the latest stable Go
gos install 1.21  # installs a specific version
gos current       # shows what you're running
```

Compare that to the manual way: visit go.dev, find the right archive for your OS and arch, download it, remove the old install, extract, verify. **gos does all of that in one command.**

Works on **macOS**, **Linux**, and **Windows** (via Git Bash or WSL). Auto-detects your OS and CPU architecture. Requires nothing but `curl` and `bash`.

---

## Table of Contents

- [Quick Start](#quick-start)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
  - [curl | bash](#curl--bash)
  - [Homebrew](#homebrew-macos--linux)
  - [PowerShell](#powershell-windows)
  - [Windows Package Managers](#windows-package-managers)
  - [Git Clone](#git-clone)
  - [Manual Shell Config](#manual-shell-configuration)
- [Usage](#usage)
- [Shell Completions](#shell-completions)
- [Configuration](#configuration)
- [How It Works](#how-it-works)
- [Uninstallation](#uninstallation)
- [Security](#security)
- [Contributing](#contributing)
- [Releasing](#releasing)
- [License](#license)

---

## Quick Start

```bash
# Install gos
curl -fsSL https://github.com/johnny4young/gos/releases/latest/download/install.sh | bash

# Install the latest stable Go
gos latest
```

Done. That's the whole setup.

---

## Features

- **One command to latest Go** — `gos latest` fetches and installs the newest stable release
- **Pin any version** — `gos install 1.21.6` gets exactly what you need
- **Auto-detects everything** — OS (`darwin`, `linux`, `windows`) and architecture (`amd64`, `arm64`, `armv6l`, `386`)
- **Cross-platform** — macOS, Linux, and Windows (Git Bash / WSL)
- **Zero dependencies** — just `curl` and `bash`, both pre-installed on most systems
- **Shell completions** — tab-completion for Bash, Zsh, and Fish
- **Lightweight** — single shell script, no compilation, no runtime

---

## Prerequisites

| Requirement | Notes |
|---|---|
| `bash` | Pre-installed on macOS and Linux. Use [Git Bash](https://gitforwindows.org/) on Windows. |
| `curl` or `wget` | `curl` is pre-installed on most systems. `wget` is used as fallback. |
| `tar` / `unzip` | `tar` for macOS/Linux, `unzip` for Windows. |
| `sudo` | Required for the default install path (`/usr/local/go`). Not needed if you override `GOS_INSTALL_DIR`. |
| `jq` or `python3` (optional) | Enables SHA256 checksum verification after download. `python3` is pre-installed on macOS. |

> **Windows users:** install with PowerShell or Git Bash. The installed `gos`
> command runs through Git Bash today, so install [Git for Windows](https://gitforwindows.org/)
> or use WSL before running `gos`.

---

## Installation

Choose the method that fits your setup.

### curl | bash

The fastest way to get started:

```bash
curl -fsSL https://github.com/johnny4young/gos/releases/latest/download/install.sh | bash
```

This downloads the latest published `gos` release and places it in `/usr/local/bin`.
The release installer pins the downloaded script to the release asset checksum.
You can customize the location. The installer creates the target directory when
possible:

```bash
curl -fsSL https://github.com/johnny4young/gos/releases/latest/download/install.sh | GOS_BIN_DIR="$HOME/.local/bin" bash
```

If you intentionally want the unreleased development version from `main`, use
the raw GitHub installer instead. This skips the release-pinned checksum path and
should only be used for testing unreleased changes.

```bash
curl -fsSL https://raw.githubusercontent.com/johnny4young/gos/main/install.sh | bash
```

### Homebrew (macOS / Linux)

```bash
brew tap johnny4young/gos
brew install gos
```

To upgrade when a new version is released:

```bash
brew upgrade gos
```

> The formula lives in [johnny4young/homebrew-gos](https://github.com/johnny4young/homebrew-gos) and is updated automatically on each release.

### PowerShell (Windows)

PowerShell is the primary Windows install path. Starting with the first release
that ships `install.ps1`, use:

```powershell
irm https://github.com/johnny4young/gos/releases/latest/download/install.ps1 | iex
```

The installer places `gos` in `%LOCALAPPDATA%\Programs\gos`, adds that directory
to your user `PATH`, verifies the release package checksum when installed from a
release asset, and warns if Git Bash is not available. It does not install Go;
after installing `gos`, run `gos latest` or `gos install <version>` when you want
to install a Go toolchain.

To update `gos`, run the same PowerShell installer again:

```powershell
irm https://github.com/johnny4young/gos/releases/latest/download/install.ps1 | iex
```

For development testing before that release asset exists:

```powershell
irm https://raw.githubusercontent.com/johnny4young/gos/main/install.ps1 | iex
```

### Windows Package Managers

Chocolatey and Winget are planned package-manager channels for Windows users,
but PowerShell is the canonical Windows installer first. Their metadata is
maintained under `packaging/` so future package-manager submissions can reuse
the same Windows release asset.

The public `choco install` and `winget install` commands are intentionally not
listed here yet. They should be added only after the packages are accepted by
their registries, so users do not copy commands that fail. Until then, use the
PowerShell installer, Git Bash, or WSL.

### Git Clone

```bash
git clone https://github.com/johnny4young/gos.git ~/.gos
ln -sf "$HOME/.gos/gos.sh" "$HOME/.gos/gos"
```

Then add to your shell profile (see [Manual Shell Configuration](#manual-shell-configuration)):

```bash
export PATH="$HOME/.gos:$PATH"
```

### Manual Shell Configuration

If you installed via git clone or want to add completions, add the following to your shell config file:

**Bash** (`~/.bashrc`):

```bash
export PATH="$HOME/.gos:$PATH"
source "$HOME/.gos/completions/gos.bash"
```

**Zsh** (`~/.zshrc`):

```bash
export PATH="$HOME/.gos:$PATH"
source "$HOME/.gos/completions/gos.zsh"
```

**Fish** (`~/.config/fish/config.fish`):

```fish
fish_add_path $HOME/.gos
source $HOME/.gos/completions/gos.fish
```

After editing, reload your shell:

```bash
source ~/.bashrc   # or ~/.zshrc
exec fish          # for Fish
```

---

## Usage

| Command | Description |
|---|---|
| `gos latest` | Install the latest stable Go version |
| `gos install <version>` | Install a specific Go version |
| `gos current` | Show the currently active Go version |
| `gos list` | List all available Go versions |
| `gos version` | Show gos version |
| `gos help` | Show help message |

### Examples

```bash
$ gos latest
Fetching latest stable Go version...
Latest: go1.24.1
Current: go1.22.0 -> go1.24.1
Downloading go1.24.1.darwin-arm64.tar.gz...
Checksum verified.
Removing old Go installation...
Extracting...
Done! go version go1.24.1 darwin/arm64

$ gos install 1.21.6
Downloading go1.21.6.linux-amd64.tar.gz...
Checksum verified.
Removing old Go installation...
Extracting...
Done! go version go1.21.6 linux/amd64

$ gos current
go1.24.1

$ gos list
Fetching available Go versions...
go1.24.1
go1.24.0
go1.23.5
go1.23.4
...
```

---

## Shell Completions

Shell completions are included for Bash, Zsh, and Fish. If you installed via `curl | bash` or Homebrew, completions may already be set up.

To manually enable them, see the [Manual Shell Configuration](#manual-shell-configuration) section above.

---

## Configuration

| Variable | Default | Description |
|---|---|---|
| `GOS_BIN_DIR` | `/usr/local/bin` | Where the `gos` command is installed by `install.sh`. Missing custom directories are created when possible. |
| `GOS_INSTALL_DIR` | `/usr/local/go` | Where Go gets installed. Override to install without `sudo`. Path basename must contain "go". |
| `GOS_REQUIRE_CHECKSUM` | unset | Set to `1` to abort installs when checksum metadata or local SHA256 calculation is unavailable. |

Example — install Go in your home directory (no sudo needed):

```bash
export GOS_INSTALL_DIR="$HOME/.go"
gos latest
```

Add the export to your shell profile to make it permanent.

> **Note:** For safety, `GOS_INSTALL_DIR` must have at least 2 path components and the basename must contain "go" (e.g. `mygo`, `golang`, `.go` all work). System-critical paths like `/usr` or `/etc` are rejected.

---

## How It Works

1. Queries the [official Go downloads API](https://go.dev/dl/?mode=json) for available versions
2. Detects your OS via `uname -s` and architecture via `uname -m`
3. Downloads the matching archive from `https://go.dev/dl/`
4. Verifies SHA256 checksum against the Go API (uses `jq` or `python3`)
5. Extracts the new version into a temporary staging directory
6. Validates the staged `go/bin/go` before touching `$GOS_INSTALL_DIR`
7. Backs up the previous Go installation, activates the staged version, and rolls back automatically if activation fails
8. Confirms with `go version`

No symlinks, no shims, no magic. Just a clean install of the official Go binary.

---

## Uninstallation

**If installed via curl | bash:**

```bash
sudo rm /usr/local/bin/gos
```

**If installed via Homebrew:**

```bash
brew uninstall gos
brew untap johnny4young/gos
```

**If installed via PowerShell on Windows:**

```powershell
& "$env:LOCALAPPDATA\Programs\gos\uninstall.ps1"
```

**If installed via git clone:**

```bash
rm -rf ~/.gos
```

Then remove the `PATH` and `source` lines from your shell config file.

---

## Security

Security reporting instructions, supported versions, and installer trust
assumptions are documented in [SECURITY.md](SECURITY.md). Do not open public
issues for sensitive vulnerability details.

---

## Contributing

Contributions are welcome! Here's how:

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Make your changes
4. Test on your platform
5. Submit a pull request

Please open an issue first for major changes so we can discuss the approach.

## Releasing

Maintainer release steps are documented in [RELEASING.md](RELEASING.md). Use it
to keep GitHub release assets, Homebrew, PowerShell, package metadata, README
install commands, and changelog links in sync.

---

## License

This project is licensed under the [MIT License](LICENSE).

---

<p align="center">
  Built for Go developers who'd rather write code than manage installations.
</p>
