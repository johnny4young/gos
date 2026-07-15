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

take_value() {
  local opt="$1" value="${2:-}"
  if [ -z "$value" ] || [ "${value#--}" != "$value" ]; then
    echo "::error::${opt} requires a value" >&2
    exit 2
  fi
  printf '%s\n' "$value"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --kind)
      kind=$(take_value "$1" "${2:-}")
      shift 2
      ;;
    --name)
      name=$(take_value "$1" "${2:-}")
      shift 2
      ;;
    --version)
      version=$(take_value "$1" "${2:-}")
      shift 2
      ;;
    --sha256)
      sha256=$(take_value "$1" "${2:-}")
      shift 2
      ;;
    --template)
      template=$(take_value "$1" "${2:-}")
      shift 2
      ;;
    --url)
      url=$(take_value "$1" "${2:-}")
      shift 2
      ;;
    --tap-repo)
      tap_repo=$(take_value "$1" "${2:-}")
      shift 2
      ;;
    --deploy-key-file)
      key_file=$(take_value "$1" "${2:-}")
      shift 2
      ;;
    *)
      echo "::error::update-homebrew-tap: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

# --- validate inputs -------------------------------------------------------------
[ -n "$name" ] || {
  echo "::error::--name is required" >&2
  exit 2
}
[ -n "$version" ] || {
  echo "::error::--version is required" >&2
  exit 2
}
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
  echo "::error::--version must be semver without a v prefix, got '$version'" >&2
  exit 1
fi
case "$name" in
  .* | *..* | *[!A-Za-z0-9._@+-]*)
    echo "::error::--name must be a safe Homebrew token, got '$name'" >&2
    exit 1
    ;;
esac
[ -n "$template" ] || {
  echo "::error::--template is required" >&2
  exit 2
}
[ -f "$template" ] || {
  echo "::error::template not found: $template" >&2
  exit 2
}
case "$kind" in
  cask)
    subdir="Casks"
    ;;
  formula)
    subdir="Formula"
    ;;
  *)
    echo "::error::--kind must be 'cask' or 'formula', got '$kind'" >&2
    exit 2
    ;;
esac
if [ "$kind" = "formula" ] && [ -z "$url" ]; then
  echo "::error::--url is required for a formula (the versioned source tarball)" >&2
  exit 2
fi
if [ -n "$url" ] && [[ "$url" != https://* ]]; then
  echo "::error::--url must use https, got '$url'" >&2
  exit 1
fi
if [[ ! "$tap_repo" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
  echo "::error::--tap-repo must use the owner/repository form, got '$tap_repo'" >&2
  exit 1
fi
if [ -n "$key_file" ] && [ ! -f "$key_file" ]; then
  echo "::error::deploy key file not found: $key_file" >&2
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
    echo "::warning::TAP_DEPLOY_KEY is not configured; update ${tap_repo} manually (RELEASING.md)."
    exit 0
  fi
  key_file="$(mktemp)"
  cleanup_key="1"
  printf '%s\n' "$TAP_DEPLOY_KEY" >"$key_file"
  chmod 600 "$key_file"
fi
# Remove the key we created on exit. The hosted runner is ephemeral, but this keeps
# the private key off disk the moment the script ends and stays correct on a
# self-hosted runner. A caller-provided key file is left untouched.
cleanup() {
  if [ -n "$cleanup_key" ]; then rm -f "$key_file"; fi
  rm -f "${known_hosts_file:-}"
  rm -f "${ssh_wrapper:-}"
}
trap cleanup EXIT

# --- pin GitHub's SSH host keys ---------------------------------------------------
# accept-new is trust-on-first-use, and every hosted runner is a first use. The
# GitHub meta API serves the current host keys over TLS (CA-validated — an
# independent trust channel from the SSH connection it protects), so build a
# known_hosts from it and require a match. If the API is unreachable, fall back
# to accept-new with a warning rather than failing the release.
known_hosts_file="$(mktemp)"
host_key_policy="accept-new"
if [ -n "${GOS_TAP_REMOTE:-}" ]; then
  : # local test remote: SSH is never used, skip the host-key fetch
elif command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
  && curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 https://api.github.com/meta 2>/dev/null \
  | jq -r '.ssh_keys[] | "github.com \(.)"' >"$known_hosts_file" 2>/dev/null \
  && [ -s "$known_hosts_file" ]; then
  host_key_policy="yes"
else
  echo "::warning::could not fetch GitHub SSH host keys from the meta API; falling back to accept-new."
fi

# --- clone the tap ---------------------------------------------------------------
# GOS_TAP_REMOTE is a test hook: the suite points it at a local bare repo so the
# publish flow can run without network or SSH.
tap_remote="${GOS_TAP_REMOTE:-git@github.com:${tap_repo}.git}"
ssh_wrapper="$(mktemp)"
cat >"$ssh_wrapper" <<'SH'
#!/bin/sh
set -eu

exec ssh \
  -i "$GOS_TAP_SSH_KEY_FILE" \
  -o IdentitiesOnly=yes \
  -o "UserKnownHostsFile=$GOS_TAP_SSH_KNOWN_HOSTS_FILE" \
  -o "StrictHostKeyChecking=$GOS_TAP_SSH_HOST_KEY_POLICY" \
  "$@"
SH
chmod 700 "$ssh_wrapper"
export GOS_TAP_SSH_KEY_FILE="$key_file"
export GOS_TAP_SSH_KNOWN_HOSTS_FILE="$known_hosts_file"
export GOS_TAP_SSH_HOST_KEY_POLICY="$host_key_policy"
export GIT_SSH="$ssh_wrapper"
export GIT_SSH_VARIANT="ssh"
unset GIT_SSH_COMMAND
tap_dir="$(mktemp -d)"
git clone --depth 1 "$tap_remote" "$tap_dir"

# --- regenerate the tap file from the in-repo template ---------------------------
# Start at the cask/class line so the template's repo-only header comment is dropped,
# then substitute the published version + checksum (+ url for a formula). Ruby treats
# the argument values as data rather than sed replacement syntax, and it verifies each
# metadata stanza occurs exactly once before writing the generated file.
tap_file="${tap_dir}/${subdir}/${name}.rb"
# First-time publish to a tap that never shipped this kind before.
mkdir -p "${tap_dir}/${subdir}"
ruby -EUTF-8 - "$kind" "$template" "$tap_file" "$version" "$sha256" "$url" <<'RUBY'
kind, template_path, tap_file, version, sha256, url = ARGV
lines = File.readlines(template_path)
start_pattern = kind == "cask" ? /^cask "/ : /^class /
start_index = lines.index { |line| line.match?(start_pattern) }

unless start_index
  warn "::error::template is missing its #{kind} declaration"
  exit 1
end

generated = lines.drop(start_index).join
updates = [["version", version], ["sha256", sha256]]
updates << ["url", url] unless url.empty?

updates.each do |label, value|
  pattern = /^  #{Regexp.escape(label)} ".*"$/
  count = generated.scan(pattern).length
  unless count == 1
    warn "::error::template must contain exactly one #{label} stanza (found #{count})"
    exit 1
  end
  generated.sub!(pattern, %(  #{label} "#{value}"))
end

File.write(tap_file, generated)
RUBY

# --- validate before it can reach users ------------------------------------------
# The substitution must have produced exactly the expected stanzas, and the Ruby must
# parse — so a mangled template/sed fails the release instead of publishing a broken
# entry that `brew install` cannot use.
grep -Fxq "  version \"${version}\"" "$tap_file" \
  || {
    echo "::error::generated ${kind} is missing the expected version stanza" >&2
    exit 1
  }
grep -Fxq "  sha256 \"${sha256}\"" "$tap_file" \
  || {
    echo "::error::generated ${kind} is missing the expected sha256 stanza" >&2
    exit 1
  }
if [ -n "$url" ]; then
  grep -Fxq "  url \"${url}\"" "$tap_file" \
    || {
      echo "::error::generated ${kind} is missing the expected url stanza" >&2
      exit 1
    }
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
# Sibling repos can bump the shared tap concurrently; rebase and retry so a
# lost push race does not fail the whole release.
push_attempt=1
until git push origin HEAD:main; do
  if [ "$push_attempt" -ge 3 ]; then
    echo "::error::failed to push to ${tap_repo} after ${push_attempt} attempts" >&2
    exit 1
  fi
  push_attempt=$((push_attempt + 1))
  sleep 2
  # Under `set -e` a failed rebase (conflict, fetch error) would abort the whole
  # script before the retry cap is reached, turning a transient race into a hard
  # failure with a half-finished rebase. Absorb the failure, clean up any
  # in-progress rebase, and let the loop retry / hit the ::error path cleanly.
  if ! git pull --rebase origin main; then
    git rebase --abort 2>/dev/null || true
    echo "::warning::rebase onto ${tap_repo} main failed on attempt $((push_attempt - 1)); retrying" >&2
  fi
done

echo "Updated ${tap_repo} → ${name} ${version}."
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "Homebrew tap updated to \`${version}\` (${name})." >>"$GITHUB_STEP_SUMMARY"
fi
