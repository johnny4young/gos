#!/usr/bin/env bash
set -euo pipefail

# Point the AUR package at a released tag. Runs after the GitHub release
# exists, because the sha256 covers the source tarball GitHub generates for
# the tag; without an explicit digest the tarball is downloaded and hashed.
#
# Usage: scripts/update-aur.bash <version> [<source-tarball-sha256>] [--dir <aur-dir>]

usage() {
  echo "Usage: scripts/update-aur.bash <version> [<source-tarball-sha256>] [--dir <aur-dir>]" >&2
}

version=""
tarball_sha=""
aur_dir=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir)
      [ "$#" -ge 2 ] || {
        usage
        exit 2
      }
      aur_dir="$2"
      shift 2
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      if [ -z "$version" ]; then
        version="$1"
      elif [ -z "$tarball_sha" ]; then
        tarball_sha="$1"
      else
        usage
        exit 2
      fi
      shift
      ;;
  esac
done
[ -n "$version" ] || {
  usage
  exit 2
}

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: invalid version '${version}' (AUR releases are stable X.Y.Z only)." >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -n "$aur_dir" ] || aur_dir="${repo_root}/packaging/aur"
pkgbuild="${aur_dir}/PKGBUILD"
srcinfo="${aur_dir}/.SRCINFO"
[ -f "$pkgbuild" ] && [ -f "$srcinfo" ] || {
  echo "Error: ${aur_dir} must contain PKGBUILD and .SRCINFO." >&2
  exit 1
}

tarball_url="https://github.com/johnny4young/gos/archive/refs/tags/v${version}.tar.gz"
if [ -z "$tarball_sha" ]; then
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  echo "Downloading ${tarball_url} to compute its sha256..."
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 120 --retry 2 -fsSL \
    -o "${tmp_dir}/source.tar.gz" "$tarball_url"
  if command -v sha256sum >/dev/null 2>&1; then
    tarball_sha="$(sha256sum "${tmp_dir}/source.tar.gz" | cut -d' ' -f1)"
  else
    tarball_sha="$(shasum -a 256 "${tmp_dir}/source.tar.gz" | cut -d' ' -f1)"
  fi
fi

if [[ ! "$tarball_sha" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Error: invalid source tarball SHA256 '${tarball_sha}'." >&2
  exit 1
fi
if [ "$tarball_sha" = "0000000000000000000000000000000000000000000000000000000000000000" ]; then
  echo "Error: placeholder SHA256 is not allowed." >&2
  exit 1
fi

# Every rewrite requires exactly one match. Both complete outputs are staged
# beside their targets before either target is replaced; if a later rename
# fails, every target already replaced is restored from its original backup.
ruby -EUTF-8 - "$pkgbuild" "$srcinfo" "$version" "$tarball_sha" "$tarball_url" <<'RUBY'
pkgbuild, srcinfo, version, sha, url = ARGV

def replace!(updates, path, pattern, replacement)
  text = updates.fetch(path) { File.read(path) }
  count = text.scan(pattern).length
  if count != 1
    warn "expected exactly one match while updating #{path}; found #{count}: #{pattern.inspect}"
    exit 1
  end
  updates[path] = text.gsub(pattern, replacement)
end

updates = {}
replace!(updates, pkgbuild, /^pkgver=.*$/, "pkgver=#{version}")
replace!(updates, pkgbuild, /^pkgrel=.*$/, "pkgrel=1")
replace!(updates, pkgbuild, /^sha256sums=\('[0-9a-f]{64}'\)$/, "sha256sums=('#{sha}')")
replace!(updates, srcinfo, /^\tpkgver = .*$/, "\tpkgver = #{version}")
replace!(updates, srcinfo, /^\tpkgrel = .*$/, "\tpkgrel = 1")
replace!(updates, srcinfo, /^\tsource = .*$/, "\tsource = gos-#{version}.tar.gz::#{url}")
replace!(updates, srcinfo, /^\tsha256sums = .*$/, "\tsha256sums = #{sha}")

staged = {}
backups = {}
touched = []
success = false

begin
  # Stage in the target directory so the later rename is atomic on that
  # filesystem. Preserve each metadata file's executable/permission bits.
  updates.each do |path, updated|
    staged_path = "#{path}.gos-new.#{Process.pid}"
    backup_path = "#{path}.gos-old.#{Process.pid}"
    if File.exist?(staged_path) || File.symlink?(staged_path) ||
       File.exist?(backup_path) || File.symlink?(backup_path)
      raise "transaction path already exists for #{path}"
    end
    mode = File.stat(path).mode & 0o7777
    File.open(staged_path, File::WRONLY | File::CREAT | File::EXCL, mode) do |file|
      staged[path] = staged_path
      file.write(updated)
      file.flush
      file.fsync
    end
    File.chmod(mode, staged_path)
    backups[path] = backup_path
  end

  updates.each_key do |path|
    touched << path
    File.rename(path, backups.fetch(path))
    File.rename(staged.fetch(path), path)
  end
  success = true
rescue => error
  restore_errors = []
  touched.reverse_each do |path|
    begin
      backup_path = backups.fetch(path)
      if File.exist?(backup_path) || File.symlink?(backup_path)
        File.delete(path) if File.exist?(path) || File.symlink?(path)
        File.rename(backup_path, path)
      end
    rescue => restore_error
      restore_errors << "#{path}: #{restore_error.message}"
    end
  end
  warn "could not update AUR metadata transactionally: #{error.message}"
  unless restore_errors.empty?
    warn "could not restore original metadata: #{restore_errors.join('; ')}"
  end
  exit 1
ensure
  staged.each_value do |path|
    File.delete(path) if File.exist?(path) || File.symlink?(path)
  end
  if success
    backups.each_value do |path|
      File.delete(path) if File.exist?(path) || File.symlink?(path)
    end
  end
end
RUBY

echo "AUR package now points at v${version} (${tarball_sha})."
echo "Publish it from a checkout of ssh://aur@aur.archlinux.org/gos.git: copy PKGBUILD and .SRCINFO, commit, push."
