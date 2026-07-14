#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="$repo_root/scripts/update-changelog.bash"

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

  cat >"$file" <<'CHANGELOG'
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

current_changelog_requires_unreleased_notes_when_ahead_of_latest_tag() {
  local changelog latest_tag notes commit_count
  changelog="$repo_root/CHANGELOG.md"

  latest_tag=$(git -C "$repo_root" describe --tags --abbrev=0 2>/dev/null || true)
  if [ -z "$latest_tag" ]; then
    printf 'ok - current changelog Unreleased guard skipped: no reachable tag\n'
    return 0
  fi

  commit_count=$(git -C "$repo_root" rev-list --count "${latest_tag}..HEAD" 2>/dev/null || printf '0')
  if [ "$commit_count" -eq 0 ]; then
    printf 'ok - current changelog Unreleased guard skipped: no post-tag commits\n'
    return 0
  fi

  notes=$(unreleased_notes "$changelog")
  if ! printf '%s\n' "$notes" | grep -Eq '^- '; then
    printf 'not ok - CHANGELOG.md has %s post-%s commit(s), but Unreleased has no bullet notes\n' "$commit_count" "$latest_tag" >&2
    exit 1
  fi

  printf 'ok - current changelog keeps post-tag notes under Unreleased\n'
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

  assert_file_contains "$changelog" "## [Unreleased]"
  assert_file_contains "$changelog" "## [1.1.0] - 2026-05-07"
  assert_file_contains "$changelog" "- Add a user-facing improvement."
  assert_file_contains "$changelog" "- Fix a release-visible issue."
  assert_file_contains "$changelog" "[Unreleased]: https://github.com/johnny4young/gos/compare/v1.1.0...HEAD"
  assert_file_contains "$changelog" "[1.1.0]: https://github.com/johnny4young/gos/compare/v1.0.0...v1.1.0"

  notes="$(unreleased_notes "$changelog")"
  if printf '%s\n' "$notes" | grep -Eq '^- '; then
    printf 'not ok - Unreleased should be reset after release\n' >&2
    exit 1
  fi

  printf 'ok - changelog release promotes curated Unreleased notes\n'
}

test_empty_unreleased_without_commits_fails_without_mutation() {
  local tmp_dir changelog before
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN
  changelog="$tmp_dir/CHANGELOG.md"

  cat >"$changelog" <<'CHANGELOG'
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

  if GOS_CHANGELOG_FILE="$changelog" GOS_RELEASE_DATE="2026-05-07" GOS_PREVIOUS_TAG="HEAD" bash "$script" "1.1.0" >/dev/null 2>&1; then
    printf 'not ok - empty Unreleased without release commits should fail\n' >&2
    exit 1
  fi

  if [[ "$(<"$changelog")" != "$before" ]]; then
    printf 'not ok - failed changelog update should not mutate file\n' >&2
    exit 1
  fi

  printf 'ok - empty Unreleased without commits fails without mutation\n'
}

test_empty_unreleased_generates_notes_from_git() {
  local tmp_dir repo changelog
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN
  repo="$tmp_dir/repo"
  mkdir "$repo"

  git -C "$repo" init -q
  git -C "$repo" config user.name "Test User"
  git -C "$repo" config user.email "test@example.com"

  printf 'initial\n' >"$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m "release: v1.0.0"
  git -C "$repo" tag v1.0.0

  printf 'feature\n' >>"$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m "feat(dx): add project-aware version switching"

  printf 'fix\n' >>"$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m "fix(installer): preserve rollback backups"

  printf 'docs\n' >>"$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m "docs: clarify release checklist"

  changelog="$repo/CHANGELOG.md"
  cat >"$changelog" <<'CHANGELOG'
# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [1.0.0] - 2025-01-15

### Added

- Initial release.

[Unreleased]: https://github.com/johnny4young/gos/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/johnny4young/gos/releases/tag/v1.0.0
CHANGELOG

  (
    cd "$repo"
    GOS_CHANGELOG_FILE="$changelog" \
      GOS_RELEASE_DATE="2026-05-07" \
      GOS_PREVIOUS_TAG="v1.0.0" \
      bash "$script" "1.1.0"
  )

  assert_file_contains "$changelog" "## [1.1.0] - 2026-05-07"
  assert_file_contains "$changelog" "### Added"
  assert_file_contains "$changelog" "- Add project-aware version switching."
  assert_file_contains "$changelog" "### Changed"
  assert_file_contains "$changelog" "- Clarify release checklist."
  assert_file_contains "$changelog" "### Fixed"
  assert_file_contains "$changelog" "- Preserve rollback backups."

  printf 'ok - empty Unreleased generates notes from git commits\n'
}

test_check_mode_validates_without_mutation() {
  local tmp_dir changelog before
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN
  changelog="$tmp_dir/CHANGELOG.md"
  write_fixture "$changelog"
  before="$(<"$changelog")"

  GOS_CHANGELOG_FILE="$changelog" \
    GOS_RELEASE_DATE="2026-05-07" \
    GOS_PREVIOUS_TAG="v1.0.0" \
    bash "$script" --check "1.1.0"

  if [[ "$(<"$changelog")" != "$before" ]]; then
    printf 'not ok - check mode should not mutate CHANGELOG.md\n' >&2
    exit 1
  fi

  printf 'ok - check mode validates without mutation\n'
}

test_check_mode_empty_unreleased_fails_without_mutation() {
  local tmp_dir changelog before
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN
  changelog="$tmp_dir/CHANGELOG.md"

  cat >"$changelog" <<'CHANGELOG'
# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [1.0.0] - 2025-01-15

### Added

- Initial release.

[Unreleased]: https://github.com/johnny4young/gos/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/johnny4young/gos/releases/tag/v1.0.0
CHANGELOG

  before="$(<"$changelog")"

  if GOS_CHANGELOG_FILE="$changelog" GOS_RELEASE_DATE="2026-05-07" GOS_PREVIOUS_TAG="HEAD" bash "$script" --check "1.1.0" >/dev/null 2>&1; then
    printf 'not ok - check mode should fail when Unreleased has no notes and no release commits\n' >&2
    exit 1
  fi

  if [[ "$(<"$changelog")" != "$before" ]]; then
    printf 'not ok - failed check mode should not mutate CHANGELOG.md\n' >&2
    exit 1
  fi

  printf 'ok - check mode empty Unreleased without commits fails without mutation\n'
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

test_heading_only_unreleased_fails_without_mutation() {
  local tmp_dir changelog before
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN
  changelog="$tmp_dir/CHANGELOG.md"

  cat >"$changelog" <<'CHANGELOG'
# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

### Fixed

## [1.0.0] - 2025-01-15

### Added

- Initial release.

[Unreleased]: https://github.com/johnny4young/gos/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/johnny4young/gos/releases/tag/v1.0.0
CHANGELOG

  before="$(<"$changelog")"

  if GOS_CHANGELOG_FILE="$changelog" GOS_RELEASE_DATE="2026-05-07" GOS_PREVIOUS_TAG="v1.0.0" bash "$script" "1.1.0" >"$tmp_dir/out" 2>&1; then
    printf 'not ok - heading-only Unreleased should fail instead of falling back to git notes\n' >&2
    exit 1
  fi

  assert_file_contains "$tmp_dir/out" 'no "- " bullet items'

  if [[ "$(<"$changelog")" != "$before" ]]; then
    printf 'not ok - heading-only Unreleased failure should not mutate CHANGELOG.md\n' >&2
    exit 1
  fi

  printf 'ok - heading-only Unreleased fails instead of silently discarding headings\n'
}

current_changelog_requires_unreleased_notes_when_ahead_of_latest_tag
test_promotes_unreleased_notes
test_empty_unreleased_without_commits_fails_without_mutation
test_empty_unreleased_generates_notes_from_git
test_check_mode_validates_without_mutation
test_check_mode_empty_unreleased_fails_without_mutation
test_existing_release_section_fails
test_heading_only_unreleased_fails_without_mutation
