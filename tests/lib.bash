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

assert_status() {
  local expected="$1" actual="$2" name="$3" output_text="$4"
  if [ "$actual" -ne "$expected" ]; then
    fail "${name}: expected status ${expected}, got ${actual}. Output: ${output_text}"
  fi
}

assert_nonzero_status() {
  local actual="$1" name="$2" output_text="$3"
  if [ "$actual" -eq 0 ]; then
    fail "${name}: expected non-zero status. Output: ${output_text}"
  fi
}

assert_json() {
  local json="$1" name="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$json" | jq -e . >/dev/null || fail "${name}: output is not valid JSON: ${json}"
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "$json" | python3 -c 'import json, sys; json.load(sys.stdin)' >/dev/null \
      || fail "${name}: output is not valid JSON: ${json}"
  else
    pass "${name}: JSON validation skipped (jq/python3 unavailable)"
  fi
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
