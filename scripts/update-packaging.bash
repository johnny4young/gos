#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: scripts/update-packaging.bash <version> <gos-windows.zip-sha256>" >&2
  exit 2
fi

version="$1"
windows_sha="$2"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
  echo "Error: invalid version '${version}'." >&2
  exit 1
fi

if [[ ! "$windows_sha" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "Error: invalid SHA256 '${windows_sha}'." >&2
  exit 1
fi

if [ "$windows_sha" = "0000000000000000000000000000000000000000000000000000000000000000" ]; then
  echo "Error: placeholder SHA256 is not allowed." >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

tag="v${version}"
windows_url="https://github.com/johnny4young/gos/releases/download/${tag}/gos-windows.zip"

# -EUTF-8 keeps file rewriting locale-independent (manifests may contain UTF-8).
ruby -EUTF-8 - "$version" "$windows_url" "$windows_sha" <<'RUBY'
version, windows_url, windows_sha = ARGV

def replace!(updates, path, pattern, replacement)
  text = updates.fetch(path) { File.read(path) }
  unless text.match?(pattern)
    warn "pattern not found while updating #{path}: #{pattern.inspect}"
    exit 1
  end
  updates[path] = text.gsub(pattern, replacement)
end

updates = {}

replace!(
  updates,
  "packaging/chocolatey/gos.nuspec",
  %r{<version>[^<]+</version>},
  "<version>#{version}</version>"
)

replace!(
  updates,
  "packaging/chocolatey/tools/chocolateyInstall.ps1",
  /^\$url = '.*'$/,
  "$url = '#{windows_url}'"
)
replace!(
  updates,
  "packaging/chocolatey/tools/chocolateyInstall.ps1",
  /^\$checksum = '.*'$/,
  "$checksum = '#{windows_sha}'"
)

replace!(
  updates,
  "packaging/winget/johnny4young.gos.yaml",
  /^PackageVersion: .*/,
  "PackageVersion: #{version}"
)
replace!(
  updates,
  "packaging/winget/johnny4young.gos.yaml",
  /^\s*InstallerUrl: .*/,
  "    InstallerUrl: #{windows_url}"
)
replace!(
  updates,
  "packaging/winget/johnny4young.gos.yaml",
  /^\s*InstallerSha256: .*/,
  "    InstallerSha256: #{windows_sha}"
)

updates.each do |path, updated|
  File.write(path, updated)
end
RUBY
