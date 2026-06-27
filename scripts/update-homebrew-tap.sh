#!/usr/bin/env bash
#
# Publish a Homebrew cask/formula bump to a central tap from a released artifact.
#
# This is the reusable core of the "each app repo bumps its own entry in the shared
# tap on release" pattern (CS-063). It regenerates the tap's cask (or formula) from
# the in-repo source template with the published version + checksum, validates the
# result, and pushes it to the tap over a write-enabled SSH deploy key. The logic is
# deliberately app-agnostic so a sibling repo (gos, …) can vendor this script verbatim
# and only change the arguments.
#
# Usage:
#   scripts/update-homebrew-tap.sh \
#     --name vitrine \
#     --version 0.16.1 \
#     --sha256 <64-lowercase-hex> \
#     --template packaging/Casks/vitrine.rb \
#     [--kind cask|formula]                 # default: cask
#     [--url <download-url>]                 # required for a formula (versioned tarball)
#     [--tap-repo johnny4young/homebrew-tap] # default
#     [--deploy-key-file <path>]             # else read the TAP_DEPLOY_KEY env var
#
# A cask's URL interpolates #{version}, so it never needs --url; a formula pins the
# versioned source tarball, so it does. When neither --deploy-key-file nor
# TAP_DEPLOY_KEY is provided the script warns and exits 0, so a fork can still release.
#
# Kept POSIX-ish and free of bash 4+ features (the macOS runner ships bash 3.2).
set -euo pipefail

# --- defaults + argument parsing -------------------------------------------------
kind="cask"
name=""
version=""
sha256=""
template=""
url=""
tap_repo="johnny4young/homebrew-tap"
key_file=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --kind) kind="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --sha256) sha256="$2"; shift 2 ;;
    --template) template="$2"; shift 2 ;;
    --url) url="$2"; shift 2 ;;
    --tap-repo) tap_repo="$2"; shift 2 ;;
    --deploy-key-file) key_file="$2"; shift 2 ;;
    *) echo "::error::update-homebrew-tap: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# --- validate inputs -------------------------------------------------------------
[ -n "$name" ] || { echo "::error::--name is required" >&2; exit 2; }
[ -n "$version" ] || { echo "::error::--version is required" >&2; exit 2; }
[ -n "$template" ] || { echo "::error::--template is required" >&2; exit 2; }
[ -f "$template" ] || { echo "::error::template not found: $template" >&2; exit 2; }
case "$kind" in
  cask) subdir="Casks"; start_marker='/^cask "/' ;;
  formula) subdir="Formula"; start_marker='/^class /' ;;
  *) echo "::error::--kind must be 'cask' or 'formula', got '$kind'" >&2; exit 2 ;;
esac
if [ "$kind" = "formula" ] && [ -z "$url" ]; then
  echo "::error::--url is required for a formula (the versioned source tarball)" >&2
  exit 2
fi

# Refuse to publish a missing, malformed, or placeholder checksum: a bad value would
# ship an entry whose `brew install` fails its integrity check for every user until
# the next release. The placeholder is the all-zeros sha in the committed template.
if ! printf '%s' "$sha256" | grep -Eq '^[0-9a-f]{64}$' \
  || [ "$sha256" = "0000000000000000000000000000000000000000000000000000000000000000" ]; then
  echo "::error::sha256 is missing, malformed, or the placeholder (got '$sha256')" >&2
  exit 1
fi

# --- resolve the deploy key (fork-friendly: warn + skip when absent) -------------
cleanup_key=""
if [ -z "$key_file" ]; then
  if [ -z "${TAP_DEPLOY_KEY:-}" ]; then
    echo "::warning::TAP_DEPLOY_KEY is not configured; update ${tap_repo} manually (docs/RELEASING.md)."
    exit 0
  fi
  key_file="$(mktemp)"
  cleanup_key="1"
  printf '%s\n' "$TAP_DEPLOY_KEY" > "$key_file"
  chmod 600 "$key_file"
fi
# Remove the key we created on exit. The hosted runner is ephemeral, but this keeps
# the private key off disk the moment the script ends and stays correct on a
# self-hosted runner. A caller-provided key file is left untouched.
cleanup() { if [ -n "$cleanup_key" ]; then rm -f "$key_file"; fi; }
trap cleanup EXIT

# --- clone the tap ---------------------------------------------------------------
export GIT_SSH_COMMAND="ssh -i ${key_file} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
tap_dir="$(mktemp -d)"
git clone --depth 1 "git@github.com:${tap_repo}.git" "$tap_dir"

# --- regenerate the tap file from the in-repo template ---------------------------
# Start at the cask/class line so the template's repo-only header comment is dropped,
# then substitute the published version + checksum (+ url for a formula). The 2-space
# indent matches `brew style`'s canonical formatting.
tap_file="${tap_dir}/${subdir}/${name}.rb"
sed_args=(-e "s|^  version \".*\"|  version \"${version}\"|" \
          -e "s|^  sha256 \".*\"|  sha256 \"${sha256}\"|")
if [ -n "$url" ]; then
  sed_args+=(-e "s|^  url \".*\"|  url \"${url}\"|")
fi
awk "${start_marker},0" "$template" | sed "${sed_args[@]}" > "$tap_file"

# --- validate before it can reach users ------------------------------------------
# The substitution must have produced exactly the expected stanzas, and the Ruby must
# parse — so a mangled template/sed fails the release instead of publishing a broken
# entry that `brew install` cannot use.
grep -Fxq "  version \"${version}\"" "$tap_file" \
  || { echo "::error::generated ${kind} is missing the expected version stanza" >&2; exit 1; }
grep -Fxq "  sha256 \"${sha256}\"" "$tap_file" \
  || { echo "::error::generated ${kind} is missing the expected sha256 stanza" >&2; exit 1; }
if [ -n "$url" ]; then
  grep -Fxq "  url \"${url}\"" "$tap_file" \
    || { echo "::error::generated ${kind} is missing the expected url stanza" >&2; exit 1; }
fi
ruby -c "$tap_file"

# --- commit + push (idempotent) --------------------------------------------------
cd "$tap_dir"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
# Stage first, then check the *staged* diff: a brand-new entry is an untracked
# file that `git diff` alone would not see, which would skip the push and
# silently never publish a first-time cask/formula.
git add "${subdir}/${name}.rb"
if git diff --cached --quiet; then
  echo "Tap already serves ${name} ${version}; nothing to push."
  exit 0
fi
git commit -m "chore(${name}): publish ${kind} v${version}"
git push origin HEAD:main

echo "Updated ${tap_repo} → ${name} ${version}."
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "Homebrew tap updated to \`${version}\` (${name})." >> "$GITHUB_STEP_SUMMARY"
fi
