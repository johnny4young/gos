#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s [output.zip]\n' "${0##*/}" >&2
}

if [ "$#" -gt 1 ]; then
  usage
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

out_path="${1:-gos-windows.zip}"
case "$out_path" in
  /*) ;;
  *) out_path="${repo_root}/${out_path}" ;;
esac

command -v zip >/dev/null 2>&1 || {
  echo "Error: zip is required to build gos-windows.zip." >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

stage_dir="${tmp_dir}/stage"
mkdir -p "$stage_dir/gos"
cp gos.sh "$stage_dir/gos/gos.sh"
cp packaging/windows/gos.cmd "$stage_dir/gos/gos.cmd"
cp packaging/windows/uninstall.ps1 "$stage_dir/gos/uninstall.ps1"
cp LICENSE "$stage_dir/gos/LICENSE"

# Keep the archive deterministic so release-time checksum automation can update
# package metadata before the tag is created and reproduce the same asset later.
find "$stage_dir/gos" -exec touch -t 200001010000 {} +
chmod -R u=rwX,go=rX "$stage_dir/gos"
# Pin the exec bit explicitly: u=rwX only preserves an existing bit, so the
# zip contents (and its checksum) must not depend on the checkout's file mode.
chmod 755 "$stage_dir/gos/gos.sh"

mkdir -p "$(dirname "$out_path")"
rm -f "$out_path"
(cd "$stage_dir" && COPYFILE_DISABLE=1 zip -X -qr "$out_path" gos)
