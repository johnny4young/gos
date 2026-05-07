#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s <version>\n' "${0##*/}" >&2
}

trim_trailing_blank_lines() {
  awk '
    { lines[NR] = $0 }
    END {
      n = NR
      while (n > 0 && lines[n] ~ /^[[:space:]]*$/) {
        n--
      }
      for (i = 1; i <= n; i++) {
        print lines[i]
      }
    }
  ' "$1"
}

version="${1:-}"
if [[ -z "$version" ]]; then
  usage
  exit 2
fi

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
  printf 'error: invalid version %q; use semver without v prefix\n' "$version" >&2
  exit 1
fi

changelog_file="${GOS_CHANGELOG_FILE:-CHANGELOG.md}"
release_date="${GOS_RELEASE_DATE:-$(date +%Y-%m-%d)}"
previous_tag="${GOS_PREVIOUS_TAG:-$(git describe --tags --abbrev=0 2>/dev/null || true)}"

if [[ ! -f "$changelog_file" ]]; then
  printf 'error: changelog file not found: %s\n' "$changelog_file" >&2
  exit 1
fi

if grep -Fq "## [${version}]" "$changelog_file"; then
  printf 'error: CHANGELOG.md already has a release section for %s\n' "$version" >&2
  exit 1
fi

raw_notes="$(mktemp)"
release_notes="$(mktemp)"
body_with_release="$(mktemp)"
body_without_links="$(mktemp)"
links_file="$(mktemp)"
body_trimmed="$(mktemp)"
next_file="$(mktemp)"
trap 'rm -f "$raw_notes" "$release_notes" "$body_with_release" "$body_without_links" "$links_file" "$body_trimmed" "$next_file"' EXIT

awk '
  $0 == "## [Unreleased]" {
    found = 1
    in_unreleased = 1
    next
  }
  in_unreleased && /^## \[[^]]+\]/ {
    in_unreleased = 0
    exit
  }
  in_unreleased {
    print
  }
  END {
    if (!found) {
      exit 2
    }
  }
' "$changelog_file" > "$raw_notes" || {
  printf 'error: CHANGELOG.md must contain ## [Unreleased]\n' >&2
  exit 1
}

awk '
  NF {
    started = 1
  }
  started {
    lines[++n] = $0
  }
  END {
    while (n > 0 && lines[n] ~ /^[[:space:]]*$/) {
      n--
    }
    for (i = 1; i <= n; i++) {
      print lines[i]
    }
  }
' "$raw_notes" > "$release_notes"

if ! grep -Eq '^- ' "$release_notes"; then
  printf 'error: ## [Unreleased] has no release-note bullets; refusing to create an empty release section\n' >&2
  exit 1
fi

awk -v version="$version" -v release_date="$release_date" -v notes_file="$release_notes" '
  function print_notes(    line) {
    while ((getline line < notes_file) > 0) {
      print line
    }
    close(notes_file)
  }

  $0 == "## [Unreleased]" {
    found = 1
    print
    print ""
    print "## [" version "] - " release_date
    print ""
    print_notes()
    print ""
    in_unreleased = 1
    next
  }

  in_unreleased && /^## \[[^]]+\]/ {
    in_unreleased = 0
    print
    next
  }

  in_unreleased {
    next
  }

  {
    print
  }

  END {
    if (!found) {
      exit 2
    }
  }
' "$changelog_file" > "$body_with_release" || {
  printf 'error: failed to rewrite CHANGELOG.md\n' >&2
  exit 1
}

awk -v links_file="$links_file" '
  /^\[[^]]+\]: / {
    print > links_file
    next
  }
  {
    print
  }
' "$body_with_release" > "$body_without_links"

trim_trailing_blank_lines "$body_without_links" > "$body_trimmed"

unreleased_link="https://github.com/johnny4young/gos/compare/v${version}...HEAD"
if [[ -n "$previous_tag" ]]; then
  release_link="https://github.com/johnny4young/gos/compare/${previous_tag}...v${version}"
else
  release_link="https://github.com/johnny4young/gos/releases/tag/v${version}"
fi

{
  cat "$body_trimmed"
  printf '\n\n[Unreleased]: %s\n' "$unreleased_link"
  printf '[%s]: %s\n' "$version" "$release_link"
  awk -v version="$version" '
    index($0, "[Unreleased]:") == 1 {
      next
    }
    index($0, "[" version "]:") == 1 {
      next
    }
    {
      print
    }
  ' "$links_file"
} > "$next_file"

mv "$next_file" "$changelog_file"
