#!/usr/bin/env bash
# Shared helpers for gos shell tests. Keep these portable for macOS bash 3.2.

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$*"
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "${name}: missing '${needle}'. Output: ${haystack}" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) fail "${name}: unexpected '${needle}'. Output: ${haystack}" ;;
  esac
}

assert_file() {
  [ -f "$1" ] || fail "missing required file $1"
}

assert_file_contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || fail "$file must contain $text"
}

assert_file_not_contains() {
  local file="$1" text="$2"
  if grep -Fq -- "$text" "$file"; then
    fail "$file must not contain $text"
  fi
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}
