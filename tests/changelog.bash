#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/update-changelog.bash"

assert_contains() {
  local file="$1"
  local expected="$2"

  if ! grep -Fq -- "$expected" "$file"; then
    printf 'not ok - expected %s to contain: %s\n' "$file" "$expected" >&2
    exit 1
  fi
}

unreleased_notes() {
  local file="$1"

  awk '
    $0 == "## [Unreleased]" {
      in_unreleased = 1
      next
    }
    in_unreleased && /^## \[[^]]+\]/ {
      exit
    }
    in_unreleased {
      print
    }
  ' "$file"
}

write_fixture() {
  local file="$1"

  cat > "$file" <<'CHANGELOG'
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- Add a user-facing improvement.

### Fixed

- Fix a release-visible issue.

## [1.0.0] - 2025-01-15

### Added

- Initial release.

[Unreleased]: https://github.com/johnny4young/gos/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/johnny4young/gos/releases/tag/v1.0.0
CHANGELOG
}

test_promotes_unreleased_notes() {
  local tmp_dir changelog notes
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN
  changelog="$tmp_dir/CHANGELOG.md"
  write_fixture "$changelog"

  GOS_CHANGELOG_FILE="$changelog" \
    GOS_RELEASE_DATE="2026-05-07" \
    GOS_PREVIOUS_TAG="v1.0.0" \
    bash "$script" "1.1.0"

  assert_contains "$changelog" "## [Unreleased]"
  assert_contains "$changelog" "## [1.1.0] - 2026-05-07"
  assert_contains "$changelog" "- Add a user-facing improvement."
  assert_contains "$changelog" "- Fix a release-visible issue."
  assert_contains "$changelog" "[Unreleased]: https://github.com/johnny4young/gos/compare/v1.1.0...HEAD"
  assert_contains "$changelog" "[1.1.0]: https://github.com/johnny4young/gos/compare/v1.0.0...v1.1.0"

  notes="$(unreleased_notes "$changelog")"
  if printf '%s\n' "$notes" | grep -Eq '^- '; then
    printf 'not ok - Unreleased should be reset after release\n' >&2
    exit 1
  fi

  printf 'ok - changelog release promotes curated Unreleased notes\n'
}

test_empty_unreleased_fails_without_mutation() {
  local tmp_dir changelog before
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN
  changelog="$tmp_dir/CHANGELOG.md"

  cat > "$changelog" <<'CHANGELOG'
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2025-01-15

### Added

- Initial release.

[Unreleased]: https://github.com/johnny4young/gos/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/johnny4young/gos/releases/tag/v1.0.0
CHANGELOG

  before="$(<"$changelog")"

  if GOS_CHANGELOG_FILE="$changelog" GOS_RELEASE_DATE="2026-05-07" GOS_PREVIOUS_TAG="v1.0.0" bash "$script" "1.1.0" >/dev/null 2>&1; then
    printf 'not ok - empty Unreleased should fail\n' >&2
    exit 1
  fi

  if [[ "$(<"$changelog")" != "$before" ]]; then
    printf 'not ok - failed changelog update should not mutate file\n' >&2
    exit 1
  fi

  printf 'ok - empty Unreleased fails without mutation\n'
}

test_existing_release_section_fails() {
  local tmp_dir changelog
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN
  changelog="$tmp_dir/CHANGELOG.md"
  write_fixture "$changelog"

  if GOS_CHANGELOG_FILE="$changelog" GOS_RELEASE_DATE="2026-05-07" GOS_PREVIOUS_TAG="v0.9.0" bash "$script" "1.0.0" >/dev/null 2>&1; then
    printf 'not ok - existing release section should fail\n' >&2
    exit 1
  fi

  printf 'ok - existing release section fails\n'
}

test_promotes_unreleased_notes
test_empty_unreleased_fails_without_mutation
test_existing_release_section_fails
