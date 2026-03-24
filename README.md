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
  - [Winget](#winget-windows)
  - [Chocolatey](#chocolatey-windows)
  - [Git Clone](#git-clone)
  - [Manual Shell Config](#manual-shell-configuration)
- [Usage](#usage)
- [Shell Completions](#shell-completions)
- [Configuration](#configuration)
- [How It Works](#how-it-works)
- [Uninstallation](#uninstallation)
- [Contributing](#contributing)
- [License](#license)

---

## Quick Start

```bash
# Install gos
curl -fsSL https://raw.githubusercontent.com/johnny4young/gos/main/install.sh | bash

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
| `jq` (optional) | Enables SHA256 checksum verification after download. Strongly recommended. |

> **Windows users:** gos runs inside Git Bash or WSL. Native `cmd.exe` and PowerShell are not directly supported.

---

## Installation

Choose the method that fits your setup.

### curl | bash

The fastest way to get started:

```bash
curl -fsSL https://raw.githubusercontent.com/johnny4young/gos/main/install.sh | bash
```

This downloads `gos` and places it in `/usr/local/bin`. You can customize the location:

```bash
GOS_BIN_DIR="$HOME/.local/bin" curl -fsSL https://raw.githubusercontent.com/johnny4young/gos/main/install.sh | bash
```

### Homebrew (macOS / Linux)

```bash
brew tap johnny4young/gos https://github.com/johnny4young/gos
brew install gos
```

> The formula lives in this repo under `Formula/gos.rb` — no separate tap repo needed. It's updated automatically on each release.

### Winget (Windows)

> **Coming soon** — manifest must be submitted to [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs).

```powershell
winget install johnny4young.gos
```

> After installing, run `gos` commands inside **Git Bash** or **WSL**.

### Chocolatey (Windows)

> **Coming soon** — package must be submitted to [community.chocolatey.org](https://community.chocolatey.org/).

```powershell
choco install gos
```

> After installing, run `gos` commands inside **Git Bash** or **WSL**.

### Git Clone

```bash
git clone https://github.com/johnny4young/gos.git ~/.gos
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
| `GOS_INSTALL_DIR` | `/usr/local/go` | Where Go gets installed. Override to install without `sudo`. Path basename must contain "go". |

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
4. Verifies SHA256 checksum against the Go API (requires `jq`)
5. Removes the previous Go installation at `$GOS_INSTALL_DIR`
6. Extracts the new version in place
7. Confirms with `go version`

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
brew untap johnny4young/gos https://github.com/johnny4young/gos
```

**If installed via Winget:**

```powershell
winget uninstall johnny4young.gos
```

**If installed via Chocolatey:**

```powershell
choco uninstall gos
```

**If installed via git clone:**

```bash
rm -rf ~/.gos
```

Then remove the `PATH` and `source` lines from your shell config file.

---

## Contributing

Contributions are welcome! Here's how:

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Make your changes
4. Test on your platform
5. Submit a pull request

Please open an issue first for major changes so we can discuss the approach.

---

## License

This project is licensed under the [MIT License](LICENSE).

---

<p align="center">
  Built for Go developers who'd rather write code than manage installations.
</p>
