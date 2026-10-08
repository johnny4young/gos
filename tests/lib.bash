#!/usr/bin/env bash
# Shared helpers for gos shell tests. Keep these portable for macOS bash 3.2.

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$*"
}

# A skipped assertion is not proof of validation. The runner supplies a private
# per-suite marker so nested test commands cannot hide that distinction in stdout.
skip_assertion() {
  printf 'skip - %s\n' "$*"
  if [ -n "${GOS_TEST_ASSERTION_SKIP_FILE:-}" ]; then
    printf 'skipped\n' >>"$GOS_TEST_ASSERTION_SKIP_FILE" || fail 'cannot record skipped assertion'
  fi
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
    skip_assertion "${name}: JSON validation skipped (jq/python3 unavailable)"
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

# True when this filesystem actually denies a write into a mode 555 directory,
# leaving the directory writable again either way. Cases that turn a denied
# write into an assertion have to probe first: root ignores the bit, and the
# Windows filesystems the completions suite runs on do not carry it at all.
readonly_bit_enforced() {
  local dir="$1" probe="${1}/.gos-write-probe" probe_wrote="false"
  chmod 555 "$dir" 2>/dev/null || return 1
  # Brace-grouped for the same reason gos.sh groups its pid write: bash reports
  # a failed redirection on the stderr in effect when it is attempted.
  if { : >"$probe"; } 2>/dev/null; then
    rm -f "$probe"
    probe_wrote="true"
  fi
  chmod 755 "$dir" 2>/dev/null || true
  # A probe that went through means the mode was ignored, so the bit is not
  # enforced. This test is the function's exit status.
  [ "$probe_wrote" = "false" ]
}
