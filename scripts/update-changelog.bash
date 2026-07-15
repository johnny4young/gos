#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s [--check] <version>\n' "${0##*/}" >&2
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

valid_release_date() {
  local value="$1" year month day max_day

  if [[ ! "$value" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then
    return 1
  fi

  year=$((10#${BASH_REMATCH[1]}))
  month=$((10#${BASH_REMATCH[2]}))
  day=$((10#${BASH_REMATCH[3]}))

  case "$month" in
    1 | 3 | 5 | 7 | 8 | 10 | 12) max_day=31 ;;
    4 | 6 | 9 | 11) max_day=30 ;;
    2)
      max_day=28
      if ((year % 400 == 0 || (year % 4 == 0 && year % 100 != 0))); then
        max_day=29
      fi
      ;;
    *) return 1 ;;
  esac

  ((year >= 1 && day >= 1 && day <= max_day))
}

generate_release_notes_from_git() {
  local output_file="$1"

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'error: ## [Unreleased] has no release-note list items and git history is unavailable\n' >&2
    return 1
  fi

  # ${previous_tag:+...} keeps this bash 3.2-safe: expanding an empty array
  # with "${range_args[@]}" is an unbound-variable error under set -u there.
  if ! git log --no-merges --reverse --format='%s' ${previous_tag:+"${previous_tag}..HEAD"} >"$commit_subjects"; then
    printf 'error: failed to read git commit subjects for changelog generation\n' >&2
    return 1
  fi

  awk '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }

    function sentence(value) {
      value = trim(value)
      if (value == "") {
        return ""
      }
      value = toupper(substr(value, 1, 1)) substr(value, 2)
      if (value !~ /[.!?]$/) {
        value = value "."
      }
      return value
    }

    function category_for(type) {
      if (type == "feat") {
        return "Added"
      }
      if (type == "fix" || type == "perf") {
        return "Fixed"
      }
      if (type == "security") {
        return "Security"
      }
      return "Changed"
    }

    {
      raw = trim($0)
      if (raw == "" || raw ~ /^release: v[0-9]/) {
        next
      }

      type = ""
      text = raw
      if (match(raw, /^[A-Za-z]+(\([^)]+\))?!?:[[:space:]]*/)) {
        prefix = substr(raw, RSTART, RLENGTH)
        type = tolower(prefix)
        sub(/\(.*/, "", type)
        sub(/!?:.*/, "", type)
        text = substr(raw, RLENGTH + 1)
      }

      text = sentence(text)
      if (text == "") {
        next
      }

      category = category_for(type)
      notes[category] = notes[category] "- " text "\n"
      seen[category] = 1
      count++
    }

    END {
      if (count == 0) {
        exit 1
      }

      order[1] = "Added"
      order[2] = "Changed"
      order[3] = "Fixed"
      order[4] = "Security"

      first = 1
      for (i = 1; i <= 4; i++) {
        category = order[i]
        if (seen[category]) {
          if (!first) {
            print ""
          }
          print "### " category
          print ""
          printf "%s", notes[category]
          first = 0
        }
      }
    }
  ' "$commit_subjects" >"$output_file" || {
    printf 'error: ## [Unreleased] has no release-note list items and no release commits were found since %s\n' "${previous_tag:-the beginning of history}" >&2
    return 1
  }
}

check_only=0
if [[ "${1:-}" == "--check" ]]; then
  check_only=1
  shift
elif [[ "${1:-}" == --* ]]; then
  usage
  exit 2
fi

if [[ "${1:-}" == --* ]]; then
  usage
  exit 2
fi

version="${1:-}"
if [[ -z "$version" || $# -ne 1 ]]; then
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

if ! valid_release_date "$release_date"; then
  printf 'error: invalid release date %q; use a real YYYY-MM-DD date\n' "$release_date" >&2
  exit 1
fi

if [[ -n "$previous_tag" && ! "$previous_tag" =~ ^(HEAD|v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?)$ ]]; then
  printf 'error: invalid previous tag %q; use HEAD or a v-prefixed semver tag\n' "$previous_tag" >&2
  exit 1
fi

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
commit_subjects="$(mktemp)"
body_with_release="$(mktemp)"
body_without_links="$(mktemp)"
links_file="$(mktemp)"
body_trimmed="$(mktemp)"
next_file="$(mktemp "${changelog_file}.tmp.XXXXXX")"
trap 'rm -f "$raw_notes" "$release_notes" "$commit_subjects" "$body_with_release" "$body_without_links" "$links_file" "$body_trimmed" "$next_file"' EXIT
cp -p "$changelog_file" "$next_file"

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
' "$changelog_file" >"$raw_notes" || {
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
' "$raw_notes" >"$release_notes"

if ! grep -Eq '^[[:space:]]*[-*] ' "$release_notes"; then
  # A non-empty section without bullets (e.g. leftover "### Added" headings)
  # is a half-edited changelog; falling back to git would silently discard
  # the curated headings.
  if [[ -s "$release_notes" ]]; then
    printf 'error: ## [Unreleased] contains content but no "- " bullet items; add bullets or remove the leftover headings\n' >&2
    exit 1
  fi
  generate_release_notes_from_git "$release_notes" || {
    printf 'hint: add at least one bullet line (e.g. "- ...") under "## [Unreleased]" in %s or use conventional commit subjects before releasing\n' "$changelog_file" >&2
    exit 1
  }
fi

if ((check_only)); then
  exit 0
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
' "$changelog_file" >"$body_with_release" || {
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
' "$body_with_release" >"$body_without_links"

trim_trailing_blank_lines "$body_without_links" >"$body_trimmed"

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
} >"$next_file"

mv "$next_file" "$changelog_file"
